"""Build the 599-frame Core ML specialization recipe from verified public GigaAM inputs.

Development only: Python 3, coremltools' MIL_pb2, protobuf, bsdiff4 1.4.4.
Usage: python generate_preview_recipe.py path/to/gigaam_v3_e2e.mlpackage gigaam-599.recipe
"""
import argparse
import hashlib
import struct
from pathlib import Path

from bsdiff4 import core
from coremltools.proto import MIL_pb2
from google.protobuf.internal.decoder import _DecodeVarint
from google.protobuf.internal.encoder import _VarintBytes

SPEC_HASH = "8e0c43329503b3b2fc41f6e594f44d7b35acdd0bd61a91bf5741557d716be957"
WEIGHTS_HASH = "706153a1e14e2b26f328f394f3eded2689865eaf2d653c021006a4f3ab3a0ec6"
SHORT_HASH = "86c4293e860749138794edabb426fa6963d138a46afa42a162e72dbc3fa194bc"
DIMENSIONS = {2499: 599, 1250: 300, 625: 150}
COPY_SPEC, LITERAL, COPY_WEIGHTS = range(3)


def rewrite_fields(message, transform):
    """Preserve field order in the pinned model envelope and feature descriptions."""
    result = bytearray()
    index = 0
    while index < len(message):
        key, index = _DecodeVarint(message, index)
        result.extend(_VarintBytes(key))
        wire_type = key % 8
        value, index = _DecodeVarint(message, index)
        if wire_type == 2:
            section = transform(key // 8, message[index:index + value])
            result.extend(_VarintBytes(len(section)))
            result.extend(section)
            index += value
        elif wire_type == 0:
            result.extend(_VarintBytes(value))
        else:
            raise ValueError(f"Unexpected field type {wire_type}")
    return bytes(result)


def description(message, depth=0):
    # ModelDescription.{input,output}.type.multiArrayType.shape is packed int64.
    def transform(field, data):
        if depth < 3:
            if field in ((1, 10), (3,), (5,))[depth]:
                return description(data, depth + 1)
        elif field == 1:
            index = 0
            packed = bytearray()
            while index < len(data):
                value, index = _DecodeVarint(data, index)
                packed.extend(_VarintBytes(DIMENSIONS.get(value, value)))
            return bytes(packed)
        return data
    return rewrite_fields(message, transform)


def resize(tensor):
    dimensions = tensor.type.tensorType.dimensions
    original = [dim.constant.size for dim in dimensions]
    for dim in dimensions:
        if dim.constant.size in DIMENSIONS:
            dim.constant.size = DIMENSIONS[dim.constant.size]
    return original


def specialize(original, weights):
    position_tables = []

    def transform(field, data):
        if field == 2:
            return description(data)
        if field != 502:
            return data
        program = MIL_pb2.Program.FromString(data)
        entry = program.functions["main"]
        for tensor in entry.inputs:
            resize(tensor)
        block, = entry.block_specializations.values()
        for op in block.operations:
            for tensor in op.outputs:
                resize(tensor)
            if op.type != "const":
                continue
            value = op.attributes["val"]
            old = resize(value)
            changed = any(dim in DIMENSIONS for dim in old)
            if changed and value.HasField("blobFileValue"):
                if old != [625, 1, 1, 48]:
                    raise ValueError("Unexpected time-dependent weight")
                weights.seek(value.blobFileValue.offset)
                magic, _, size, offset = struct.unpack("<IIQQ", weights.read(24))
                if magic != 0xDEADBEEF or size != 625 * 48 * 2:
                    raise ValueError("Malformed positional table")
                weights.seek(offset)
                prefix = weights.read(150 * 48 * 2)
                position_tables.append((offset, prefix))
                value.ClearField("blobFileValue")
                value.immediateValue.tensor.bytes.values = prefix
            elif value.HasField("immediateValue") and value.immediateValue.tensor.HasField("ints"):
                ints = value.immediateValue.tensor.ints.values
                if changed:
                    if list(ints) != list(range(old[-1])):
                        raise ValueError("Unexpected time mask")
                    del ints[DIMENSIONS[old[-1]]:]
                else:
                    for i, number in enumerate(ints):
                        ints[i] = DIMENSIONS.get(number, number)
        return program.SerializeToString(deterministic=True)

    short = rewrite_fields(original, transform)
    if len(position_tables) != 2 or hashlib.sha256(short).hexdigest() != SHORT_HASH:
        raise ValueError("Unexpected specialized graph")
    return short, position_tables


def spec_operations(original, target):
    """Compress a structural section as old-spec ranges and short literal insertions."""
    control, differences, _ = core.diff(original, target)
    source = dest = diff = 0
    for length, inserted, seek in struct.iter_unpack("<qqq", control):
        if seek < -(1 << 60):  # BSDIFF40 uses sign-magnitude integers.
            seek = -(seek % (1 << 63))
        i = 0
        while i < length:
            equal = differences[diff + i] == 0
            end = i + 1
            while end < length and (differences[diff + end] == 0) == equal:
                end += 1
            if equal and end - i >= 6:
                yield [COPY_SPEC, source + i, end - i]
            else:
                yield [LITERAL, target[dest + i:dest + end]]
            i = end
        source += length + seek
        dest += length
        diff += length
        if inserted:
            yield [LITERAL, target[dest:dest + inserted]]
            dest += inserted
    if dest != len(target):
        raise ValueError("Incomplete delta")


def make_recipe(original, short, tables):
    ops = []
    cursor = 0
    for position, offset, table in sorted((short.index(data), offset, data) for offset, data in tables):
        if short.count(table) != 1:
            raise ValueError("Ambiguous positional table")
        ops.extend(spec_operations(original, short[cursor:position]))
        ops.append([COPY_WEIGHTS, offset, len(table)])
        cursor = position + len(table)
    ops.extend(spec_operations(original, short[cursor:]))

    compact = []
    for op in ops:
        last = compact[-1] if compact else None
        if last and last[0] == op[0] == LITERAL:
            last[1] += op[1]
        elif last and last[0] == op[0] == COPY_SPEC and last[1] + last[2] == op[1]:
            last[2] += op[2]
        else:
            compact.append(op)
    recipe = bytearray()
    for opcode, *args in compact:
        recipe.append(opcode)
        if opcode == LITERAL:
            recipe.extend(_VarintBytes(len(args[0])))
            recipe.extend(args[0])
        else:
            for number in args:
                recipe.extend(_VarintBytes(number))
    return recipe


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    files = args.package / "Data/com.apple.CoreML"
    original = (files / "model.mlmodel").read_bytes()
    with (files / "weights/weight.bin").open("rb") as weights:
        if hashlib.sha256(original).hexdigest() != SPEC_HASH or hashlib.file_digest(weights, "sha256").hexdigest() != WEIGHTS_HASH:
            raise ValueError("The input must be the pinned public GigaAM v3 E2E CTC package")
        short, tables = specialize(original, weights)
    args.output.write_bytes(make_recipe(original, short, tables))
