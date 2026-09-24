#!/usr/bin/env bash

set -euo pipefail

# Pandoc reads command-line metadata using the active process locale. A plain
# C locale corrupts accented Latin and Greek characters passed in localized
# titles even though the UTF-8 Markdown body remains intact. Select an
# available UTF-8 locale so the generated title page and PDF text layer match.
current_locale=${LC_ALL:-${LC_CTYPE:-${LANG:-}}}
if [[ ! "$current_locale" =~ [Uu][Tt][Ff]-?8 ]]; then
    for utf8_locale in C.UTF-8 C.utf8 en_US.UTF-8; do
        if locale -a 2>/dev/null | grep -Fqix "$utf8_locale"; then
            export LC_ALL=$utf8_locale
            break
        fi
    done
fi

[[ ${LC_ALL:-${LC_CTYPE:-${LANG:-}}} =~ [Uu][Tt][Ff]-?8 ]] || {
    echo "A UTF-8 locale is required to build the localized operator manuals." >&2
    exit 1
}

usage() {
    echo "Usage: $0 <release-version> [output-directory]" >&2
    exit 2
}

[[ $# -ge 1 && $# -le 2 ]] || usage

version=${1#v}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../.." && pwd)
manual_dir="$repo_root/include/osh-oakridge-modules/services/sensorhub-service-oscar/src/main/resources/com/botts/impl/service/oscar/i18n"
image_dir="$repo_root/include/osh-oakridge-modules/docs/oscar-operator-manual/images"
output_dir=${2:-"$repo_root/build/documentation"}
header_file="$script_dir/operator-manual-header.tex"
table_filter="$script_dir/operator-manual-tables.lua"

for command_name in pandoc xelatex pdfinfo pdftotext pdftoppm python3; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "Required documentation tool is unavailable: $command_name" >&2
        exit 1
    }
done

[[ -d "$manual_dir" ]] || {
    echo "Manual source directory is missing: $manual_dir" >&2
    exit 1
}
[[ -d "$image_dir" ]] || {
    echo "Manual image directory is missing: $image_dir" >&2
    exit 1
}
[[ -f "$header_file" ]] || {
    echo "PDF style header is missing: $header_file" >&2
    exit 1
}
[[ -f "$table_filter" ]] || {
    echo "PDF table filter is missing: $table_filter" >&2
    exit 1
}

mkdir -p "$output_dir"
temp_dir=$(mktemp -d)
trap 'rm -rf "$temp_dir"' EXIT

locales=(en es fr el)
sources=(README.md README_es.md README_fr.md README_el.md)
titles=(
    "OSCAR Administrator and Operator Manual"
    "Manual de administración y operación de OSCAR"
    "Manuel d'administration et d'exploitation d'OSCAR"
    "Εγχειρίδιο διαχείρισης και λειτουργίας OSCAR"
)
language_names=(English Español Français Ελληνικά)
toc_titles=(Contents Índice "Table des matières" Περιεχόμενα)
expected_text=(
    "administrator and operator manual"
    "administración y operación"
    "administration et d'exploitation"
    "διαχείρισης και λειτουργίας"
)

raw_image_prefix="https://raw.githubusercontent.com/Botts-Innovative-Research/osh-oakridge-modules/main/docs/oscar-operator-manual/images/"

for index in "${!locales[@]}"; do
    locale=${locales[$index]}
    source_file="$manual_dir/${sources[$index]}"
    prepared_file="$temp_dir/manual-$locale.md"
    output_file="$output_dir/OSCAR-$version-Administrator-Operator-Manual-$locale.pdf"

    [[ -f "$source_file" ]] || {
        echo "Localized manual is missing: $source_file" >&2
        exit 1
    }

    python3 - "$source_file" "$prepared_file" "$raw_image_prefix" "$image_dir" <<'PY'
from pathlib import Path
import re
import sys

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
raw_prefix = sys.argv[3]
image_dir = Path(sys.argv[4]).resolve()

text = source.read_text(encoding="utf-8")
lines = text.splitlines()
if lines and lines[0].startswith("# "):
    lines = lines[1:]

# The PDF receives a generated, page-numbered table of contents. Remove the
# hand-authored Markdown contents block from the temporary copy so it does not
# become a numbered section or offset every real section by one.
contents_headings = {"## Contents", "## Contenido", "## Sommaire", "## Περιεχόμενα"}
for start, line in enumerate(lines):
    if line.strip() not in contents_headings:
        continue
    end = start + 1
    while end < len(lines) and not lines[end].startswith("## "):
        end += 1
    del lines[start:end]
    break

# The Markdown manual uses H1 for its title and H2 for top-level sections.
# The title moves into PDF metadata, so promote the remaining headings to keep
# PDF section numbers at 1, 1.1, 1.1.1 instead of 0.1, 0.1.1, 0.1.1.1.
in_fence = False
for index, line in enumerate(lines):
    if line.lstrip().startswith("```"):
        in_fence = not in_fence
    elif not in_fence and line.startswith("##"):
        promoted = line[1:]
        # Markdown headings already carry operator-facing section numbers.
        # Pandoc supplies PDF numbering, so remove the literal prefix from the
        # prepared copy to avoid headings such as "9.2 8.2 Event Details".
        lines[index] = re.sub(
            r"^(#{1,6})\s+\d+(?:\.\d+)*\.?\s+",
            r"\1 ",
            promoted,
        )

text = "\n".join(lines).lstrip()
# Keep the hand-authored Contents links valid after removing the numeric
# heading prefixes in the PDF-only copy (for example #8-operate... becomes
# #operate...). The generated Pandoc table of contents uses the same targets.
text = re.sub(r"\]\(#\d+-", "](#", text)
text = text.replace(raw_prefix, image_dir.as_uri() + "/")
destination.write_text(text, encoding="utf-8")
PY

    pandoc "$prepared_file" \
        --from=gfm \
        --standalone \
        --toc \
        --toc-depth=3 \
        --number-sections \
        --pdf-engine=xelatex \
        --lua-filter="$table_filter" \
        --include-in-header="$header_file" \
        --metadata="title:${titles[$index]}" \
        --metadata="subtitle:OSCAR $version - ${language_names[$index]}" \
        --metadata="toc-title:${toc_titles[$index]}" \
        --metadata="author:Botts Innovative Research" \
        --metadata="lang:$locale" \
        --variable="mainfont:Noto Sans" \
        --variable="sansfont:Noto Sans" \
        --variable="monofont:Noto Sans Mono" \
        --variable="fontsize:10pt" \
        --variable="geometry:letterpaper,margin=0.72in,headheight=16pt" \
        --variable="colorlinks:true" \
        --variable="linkcolor:OSCARBlue" \
        --variable="urlcolor:OSCARBlue" \
        --output="$output_file"

    [[ -s "$output_file" ]] || {
        echo "PDF was not created: $output_file" >&2
        exit 1
    }

    page_count=$(pdfinfo "$output_file" | awk '/^Pages:/ {print $2}')
    [[ "$page_count" =~ ^[0-9]+$ && "$page_count" -ge 20 ]] || {
        echo "PDF has an unexpected page count ($page_count): $output_file" >&2
        exit 1
    }

    extracted_text="$temp_dir/manual-$locale.txt"
    pdftotext "$output_file" "$extracted_text"
    grep -Fqi "${expected_text[$index]}" "$extracted_text" || {
        echo "Localized text validation failed: $output_file" >&2
        exit 1
    }
    grep -Fq "OSCAR $version" "$extracted_text" || {
        echo "Release-version validation failed: $output_file" >&2
        exit 1
    }

    # Reject any text whose rendered bounding box enters the page-edge safety
    # area. This guards against clipped tables and unbroken CSV records.
    bbox_file="$temp_dir/manual-$locale-bbox.html"
    pdftotext -bbox-layout "$output_file" "$bbox_file"
    python3 - "$bbox_file" "$output_file" <<'PY'
import sys
import xml.etree.ElementTree as ET

bbox_path, pdf_path = sys.argv[1:]
root = ET.parse(bbox_path).getroot()
violations = []
for page_number, page in enumerate(root.iter("{http://www.w3.org/1999/xhtml}page"), 1):
    width = float(page.attrib["width"])
    for word in page.iter("{http://www.w3.org/1999/xhtml}word"):
        x_min = float(word.attrib["xMin"])
        x_max = float(word.attrib["xMax"])
        # Keep glyphs inside a 2/3-inch safe area. The PDF uses 0.72-inch
        # margins; the small tolerance permits normal glyph overhang while
        # still detecting prose that leaks into the non-printable edge.
        safe_inset = 47.0
        if x_min < safe_inset or x_max > width - safe_inset:
            violations.append((page_number, x_min, x_max, "".join(word.itertext())))

if violations:
    print(f"Text crosses a page boundary in {pdf_path}:", file=sys.stderr)
    for item in violations[:20]:
        print(f"  page {item[0]}: x={item[1]:.2f}..{item[2]:.2f} {item[3]!r}", file=sys.stderr)
    sys.exit(1)
PY

    pdftoppm -f 1 -singlefile -png -r 96 "$output_file" "$temp_dir/render-$locale" >/dev/null 2>&1
    [[ -s "$temp_dir/render-$locale.png" ]] || {
        echo "PDF rendering validation failed: $output_file" >&2
        exit 1
    }

    echo "Created $(basename "$output_file") ($page_count pages)"
done
