[Environment]::SetEnvironmentVariable(
  "Path",
  $Env:Path + ";$HOME\bin",
  [EnvironmentVariableTarget]::User
)
