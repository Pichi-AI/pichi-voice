#!/bin/bash
set -euo pipefail
pichi_brand_root="$(cd "$(dirname "$0")/../.." && pwd)"
pichi_brand_tool_dir="$(mktemp -d /tmp/voice-brand-tool.XXXXXX)"
trap 'rm -rf "$pichi_brand_tool_dir"' EXIT HUP INT TERM
xcrun swiftc -parse-as-library \
    "$pichi_brand_root/Sources/Fluid/Localization/PichiLocalization.swift" \
    "$pichi_brand_root/Sources/Fluid/Branding/AppBrand.swift" \
    "$pichi_brand_root/Sources/Fluid/Branding/BrandPackage.swift" \
    "$pichi_brand_root/Sources/Fluid/Branding/BrandDistribution.swift" \
    "$pichi_brand_root/Tests/BrandDistributionTool.swift" -o "$pichi_brand_tool_dir/prepare"
"$pichi_brand_tool_dir/prepare" "$@"
