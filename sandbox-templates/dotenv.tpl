{{- range $key, $val := (ds "ctx").secrets -}}
{{$key}}={{$val | quote}}
{{end -}}
