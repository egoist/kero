#!/bin/zsh
set -euo pipefail

# Downloads all Ghostty theme files from iTerm2-Color-Schemes and generates
# Swift source files for the GhosttyTheme library.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$ROOT_DIR/Sources/GhosttyTheme/Themes"
TEMP_DIR="$(mktemp -d)"

trap 'rm -rf "$TEMP_DIR"' EXIT

mkdir -p "$OUTPUT_DIR"

# Fetch the list of theme files from GitHub API
echo "[+] fetching theme list from github api"
curl -sL "https://api.github.com/repos/mbadolato/iTerm2-Color-Schemes/contents/ghostty" \
    | python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data:
    if item['type'] == 'file':
        print(item['name'])
" > "$TEMP_DIR/theme_list.txt"

THEME_COUNT=$(wc -l < "$TEMP_DIR/theme_list.txt" | tr -d ' ')
echo "[+] found $THEME_COUNT themes"

# Download all themes
echo "[+] downloading themes"
mkdir -p "$TEMP_DIR/themes"
while IFS= read -r name; do
    encoded_name=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$name'))")
    curl -sL "https://raw.githubusercontent.com/mbadolato/iTerm2-Color-Schemes/master/ghostty/$encoded_name" \
        -o "$TEMP_DIR/themes/$name" &
    # Limit concurrent downloads
    if (( $(jobs -r | wc -l) >= 20 )); then
        wait -n
    fi
done < "$TEMP_DIR/theme_list.txt"
wait
echo "[+] downloaded all themes"

# Generate Swift files using Python
echo "[+] generating swift source files"
python3 - "$TEMP_DIR/themes" "$OUTPUT_DIR" "$TEMP_DIR/theme_list.txt" << 'PYEOF'
import os, sys, re, string

themes_dir = sys.argv[1]
output_dir = sys.argv[2]
list_file = sys.argv[3]

with open(list_file) as f:
    theme_names = [line.strip() for line in f if line.strip()]

def parse_theme(path):
    result = {}
    palette = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            if '=' not in line:
                continue
            key, _, value = line.partition('=')
            key = key.strip()
            value = value.strip()
            if key == 'palette':
                # format: N=#RRGGBB or N=RRGGBB
                idx_str, _, color = value.partition('=')
                idx = int(idx_str.strip())
                color = color.strip().lstrip('#')
                palette[idx] = color
            else:
                # strip # from color values
                clean_val = value.lstrip('#')
                result[key] = clean_val
    result['_palette'] = palette
    return result

def swift_identifier(name):
    """Convert theme name to a valid Swift identifier."""
    # Replace + with Plus before stripping
    ident = name.replace('+', 'Plus')
    # Replace non-alphanumeric with underscore
    ident = re.sub(r'[^a-zA-Z0-9]', '_', ident)
    # Collapse multiple underscores
    ident = re.sub(r'_+', '_', ident)
    # Strip leading/trailing underscores
    ident = ident.strip('_')
    # Prefix with underscore if starts with digit
    if ident and ident[0].isdigit():
        ident = '_' + ident
    # camelCase: lowercase first char
    if ident:
        ident = ident[0].lower() + ident[1:]
    return ident

def swift_string(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'

def optional_field(data, ghostty_key, swift_type="String"):
    val = data.get(ghostty_key)
    if val:
        return swift_string(val)
    return "nil"

# Group themes by first letter
groups = {}
all_themes = []

for name in sorted(theme_names, key=str.lower):
    path = os.path.join(themes_dir, name)
    if not os.path.isfile(path):
        continue
    try:
        data = parse_theme(path)
    except Exception as e:
        print(f"  [-] skipping {name}: {e}", file=sys.stderr)
        continue

    bg = data.get('background')
    fg = data.get('foreground')
    if not bg or not fg:
        print(f"  [-] skipping {name}: missing background/foreground", file=sys.stderr)
        continue

    ident = swift_identifier(name)
    first_char = name[0].upper()
    if first_char not in string.ascii_uppercase:
        first_char = 'Symbols'

    palette = data.get('_palette', {})
    palette_str = '['
    for i in sorted(palette.keys()):
        palette_str += f'{i}: {swift_string(palette[i])}, '
    if palette_str.endswith(', '):
        palette_str = palette_str[:-2]
    palette_str += ']'

    entry = {
        'name': name,
        'ident': ident,
        'background': swift_string(bg),
        'foreground': swift_string(fg),
        'cursorColor': optional_field(data, 'cursor-color'),
        'cursorText': optional_field(data, 'cursor-text'),
        'selectionBackground': optional_field(data, 'selection-background'),
        'selectionForeground': optional_field(data, 'selection-foreground'),
        'palette': palette_str,
        'group': first_char,
    }

    groups.setdefault(first_char, []).append(entry)
    all_themes.append(entry)

# Write per-group Swift files
for group, entries in sorted(groups.items()):
    filename = f"Themes_{group}.swift"
    filepath = os.path.join(output_dir, filename)
    with open(filepath, 'w') as f:
        f.write("// Auto-generated by Script/generate-themes.sh — do not edit\n\n")
        f.write("public extension GhosttyThemeDefinition {\n")
        for e in entries:
            f.write(f"    static let {e['ident']} = GhosttyThemeDefinition(\n")
            f.write(f"        name: {swift_string(e['name'])},\n")
            f.write(f"        background: {e['background']},\n")
            f.write(f"        foreground: {e['foreground']},\n")
            f.write(f"        cursorColor: {e['cursorColor']},\n")
            f.write(f"        cursorText: {e['cursorText']},\n")
            f.write(f"        selectionBackground: {e['selectionBackground']},\n")
            f.write(f"        selectionForeground: {e['selectionForeground']},\n")
            f.write(f"        palette: {e['palette']}\n")
            f.write(f"    )\n\n")
        f.write("}\n")
    print(f"  [+] wrote {filename} ({len(entries)} themes)")

# Write catalog file
catalog_path = os.path.join(output_dir, "ThemeCatalog_Generated.swift")
with open(catalog_path, 'w') as f:
    f.write("// Auto-generated by Script/generate-themes.sh — do not edit\n\n")
    f.write("public extension GhosttyThemeCatalog {\n")
    f.write("    static let allThemes: [GhosttyThemeDefinition] = [\n")
    for e in all_themes:
        f.write(f"        .{e['ident']},\n")
    f.write("    ]\n")
    f.write("}\n")
    print(f"  [+] wrote ThemeCatalog_Generated.swift ({len(all_themes)} themes)")

print(f"[+] generated {len(all_themes)} themes total")
PYEOF

echo "[+] done"
