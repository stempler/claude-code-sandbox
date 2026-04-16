{{- /*
  Renders secrets as shell KEY="value" lines.
  Uses gomplate's `quote` function (Sprig/Go fmt.Sprintf("%q")), which
  properly escapes embedded double-quotes as \" and backslashes as \\.
*/ -}}
{{- range $key, $val := (ds "ctx").secrets -}}
{{$key}}={{$val | quote}}
{{end -}}
