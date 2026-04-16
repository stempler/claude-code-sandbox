{{- /*
  Renders secrets as Java .properties key=value lines.
  Note: Values containing special characters (=, :, #, !) are not escaped.
  Ensure secrets do not contain these characters, or use a custom template.
*/ -}}
{{- range $key, $val := (ds "ctx").secrets -}}
{{$key}}={{$val}}
{{end -}}
