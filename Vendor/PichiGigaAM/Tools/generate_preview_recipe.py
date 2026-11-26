"""Build the short and long Core ML graph recipes from verified public GigaAM inputs.

Development only: Python 3, coremltools' MIL_pb2, protobuf, bsdiff4 1.4.4.
Usage: python generate_preview_recipe.py path/to/gigaam_v3_e2e.mlpackage gigaam-599.recipe
"""
import argparse
import copy
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


def mask_attention(spec, frames):
    """Exclude padded key positions in each attention block before softmax."""
    def renamed(template, name, **inputs):
        op = copy.deepcopy(template)
        op.outputs[0].name = name
        op.attributes["name"].immediateValue.tensor.strings.values[0] = name
        for key, source in inputs.items():
            op.inputs[key].arguments[0].name = source
        return op

    def transform(field, data):
        if field != 502:
            return data
        program = MIL_pb2.Program.FromString(data)
        block, = program.functions["main"].block_specializations.values()
        ops = list(block.operations)
        named = {out.name: op for op in ops for out in op.outputs}
        pad = named["bitwise_not"]
        if [d.constant.size for d in pad.outputs[0].type.tensorType.dimensions] != [1, frames]:
            raise ValueError("Unexpected encoded padding mask")
        zero = named["const_46_to_fp16"]
        penalty = renamed(zero, "masked_key_logit")
        penalty.attributes["val"].immediateValue.tensor.bytes.values = struct.pack("<e", -10000)
        bias = renamed(named["masked_fill_1_cast_fp16"], "attention_padding", cond="bitwise_not",
                       a=penalty.outputs[0].name, b=zero.outputs[0].name)
        bias.outputs[0].type.CopyFrom(pad.outputs[0].type)
        bias.outputs[0].type.tensorType.dataType = zero.outputs[0].type.tensorType.dataType
        updated = []
        attention_blocks = 0
        for op in ops:
            shape = [d.constant.size for d in op.outputs[0].type.tensorType.dimensions]
            if op.type == "softmax" and len(shape) == 4:
                source = op.inputs["x"].arguments[0].name
                if named[source].type != "matmul" or shape != [1, 16, frames, frames]:
                    raise ValueError("Unexpected attention logits")
                name = "masked_" + source
                add = renamed(named["add_8_cast_fp16"], name, x=source, y=bias.outputs[0].name)
                add.outputs[0].type.CopyFrom(named[source].outputs[0].type)
                updated.append(add)
                op.inputs["x"].arguments[0].name = name
                attention_blocks += 1
            updated.append(op)
            if op is pad:
                updated.extend([penalty, bias])
        if attention_blocks != 16:
            raise ValueError("Expected one attention adjustment in each of the 16 encoder blocks")
        del block.operations[:]
        block.operations.extend(updated)
        return program.SerializeToString(deterministic=True)
    return rewrite_fields(spec, transform)


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
    parser.add_argument("--long", action="store_true", help="Generate the canonical 2499-frame attention recipe")
    args = parser.parse_args()
    files = args.package / "Data/com.apple.CoreML"
    original = (files / "model.mlmodel").read_bytes()
    with (files / "weights/weight.bin").open("rb") as weights:
        if hashlib.sha256(original).hexdigest() != SPEC_HASH or hashlib.file_digest(weights, "sha256").hexdigest() != WEIGHTS_HASH:
            raise ValueError("The input must be the pinned public GigaAM v3 E2E CTC package")
        if args.long:
            target, tables = mask_attention(original, 625), []
        else:
            short, tables = specialize(original, weights)
            target = mask_attention(short, 150)
    args.output.write_bytes(make_recipe(original, target, tables))
