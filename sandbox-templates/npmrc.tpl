{{- $secrets := (ds "ctx").secrets -}}
{{- if has $secrets "registry" -}}
registry={{ index $secrets "registry" }}
{{- end }}
//registry.npmjs.org/:_authToken={{ required "authToken is required" (index $secrets "authToken") }}
