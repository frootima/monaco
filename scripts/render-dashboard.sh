#!/bin/sh
set -eu

dashboard_dir="${1:-projects/kafka-reds-observability/dashboard}"
variables_file="${dashboard_dir}/env.json"
template_file="${dashboard_dir}/template.json"
output_file="${dashboard_dir}/dashboard.json"
temporary_file="${output_file}.tmp.$$"

trap 'rm -f "$temporary_file"' EXIT

jq -e '
  type == "object"
  and (keys | all(test("^[A-Za-z][A-Za-z0-9_]*$")))
' "$variables_file" >/dev/null

jq --slurpfile variable_files "$variables_file" '
  ($variable_files[0]) as $variables
  | def render:
      if type == "object" then
        with_entries(.value |= render)
      elif type == "array" then
        map(render)
      elif type == "string" then
        . as $text
        | ($variables
          | to_entries
          | map(select($text == ("{{" + .key + "}}")))
          | first) as $exact
        | if $exact == null then
            reduce ($variables | to_entries[]) as $variable
              ($text;
                gsub("\\{\\{" + $variable.key + "\\}\\}";
                  ($variable.value | tostring)))
          else
            $exact.value
          end
      else
        .
      end;
    render
' "$template_file" > "$temporary_file"

if jq -e '.. | strings | select(test("\\{\\{[^{}]+\\}\\}"))' \
  "$temporary_file" >/dev/null; then
  echo "Unresolved dashboard template variable found." >&2
  exit 1
fi

jq -e . "$temporary_file" >/dev/null
mv "$temporary_file" "$output_file"
trap - EXIT

echo "Rendered ${output_file} from ${template_file} and ${variables_file}."
