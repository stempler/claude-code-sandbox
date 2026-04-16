{{- $secrets := (ds "ctx").secrets -}}
machine {{ required "machine is required" (index $secrets "machine") }}
login {{ required "login is required" (index $secrets "login") }}
password {{ required "password is required" (index $secrets "password") }}
