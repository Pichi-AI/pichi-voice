#!/bin/sh
# Publish the GitHub guides as static HTML using Pandoc's GitHub Markdown reader.
set -eu
cd "$(dirname "$0")/../.."

render() {
    source=$1
    home=$2
    language=$3
    toc=$4
    skip=$5
    output="website/dist${home}docs/index.html"
    mkdir -p "$(dirname "$output")"
    pandoc "$source" --from=gfm --to=html5 --standalone --wrap=none \
        --lua-filter=website/guide/site-links.lua --template=website/guide/page.html \
        --toc --toc-depth=2 --metadata "lang=$language" --metadata "home=$home" \
        --metadata "contents=$toc" --metadata "skip-link=$skip" --output="$output"
}

render docs/product/user-guide.md /voice/ en "On this page" "Skip to the guide"
render docs/product/user-guide.ru.md /ru/voice/ ru "В этом руководстве" "Перейти к руководству"
