@echo off
REM ============================================================
REM Script to generate Dart code from .proto files
REM ============================================================
REM
REM PREREQUISITES:
REM 1. Install protoc:
REM    - Download from: https://github.com/protocolbuffers/protobuf/releases
REM    - Extract protoc.exe to a folder in PATH
REM    - OR with Chocolatey: choco install protoc
REM    - OR with Scoop: scoop install protobuf
REM
REM 2. Activate Dart plugin (already done via pubspec.yaml):
REM    dart pub global activate protoc_plugin
REM
REM ============================================================

echo.
echo === Protobuf Code Generator ===
echo.

REM Check if protoc is installed
where protoc >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo ERROR: protoc is not installed!
    echo.
    echo To install protoc:
    echo   1. Download from: https://github.com/protocolbuffers/protobuf/releases
    echo   2. Extract protoc.exe to a folder in PATH
    echo.
    echo OR use our manual implementation in lib/services/metadata_proto.dart
    echo which is already functional and compatible with protobuf wire format.
    echo.
    pause
    exit /b 1
)

echo protoc found:
protoc --version
echo.

REM Ensure Dart plugin is activated (version 21.1.2 compatible with protobuf 3.1.0)
echo Activating protoc-gen-dart plugin v21.1.2...
call dart pub global activate protoc_plugin 21.1.2
echo.
REM Create output directory
if not exist "lib\generated" mkdir "lib\generated"

REM Generate Dart code
echo Generating Dart code...
protoc --dart_out=lib/generated ^
       --proto_path=lib/generated ^
       lib/generated/message.proto

if %ERRORLEVEL% equ 0 (
    echo.
    echo === Success! ===
    echo Code generated in: lib/generated/
    echo.
) else (
    echo.
    echo === Error during generation ===
    echo.
)

pause
