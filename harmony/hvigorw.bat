@if "%DEBUG%" == "" @echo off
@rem Thin wrapper: delegate to the hvigor bootstrap shipped with the local
@rem command-line-tools installation (see hvigorw for details).
set "HVIGOR_CLI=%HVIGOR_CLI%"
if "%HVIGOR_CLI%"=="" set "HVIGOR_CLI=C:\Huawei\CommandLineTools\hvigor\bin\hvigorw.bat"

if not exist "%HVIGOR_CLI%" (
  echo ERROR: hvigor bootstrap not found at: %HVIGOR_CLI% >&2
  echo Install DevEco command-line-tools or set HVIGOR_CLI. >&2
  exit /b 1
)

call "%HVIGOR_CLI%" %*
