#!/usr/bin/env bash
# Checks the alarm guard's decisions (android/.../RingGuard.kt) without a
# phone: the file is compiled against small stand-ins for the Android and
# alarm-plugin classes it uses (stubs/), and Guard.kt walks it through
# each case: answered, still ringing, closed while ringing, moved later,
# given up, after an update, after a restart.
#
#   tool/guard_check/run.sh [folder holding the Kotlin compiler jars]
# Any Gradle installation's lib folder has them (default /opt/gradle-*/lib).
set -euo pipefail
cd "$(dirname "$0")"
L="${1:-$(ls -d /opt/gradle-*/lib | head -1)}"
CP=$(ls "$L"/kotlin-compiler-embeddable-*.jar "$L"/kotlin-stdlib-*.jar "$L"/kotlin-script-runtime-*.jar \
  "$L"/kotlin-reflect-*.jar "$L"/kotlinx-coroutines-core-jvm-*.jar "$L"/trove4j-*.jar "$L"/annotations-*.jar \
  "$L"/kotlin-daemon-embeddable-*.jar | tr '\n' ':')
STD=$(ls "$L"/kotlin-stdlib-2*.jar | head -1)
K=../../android/app/src/main/kotlin/com/brainoclock/app
OUT=$(mktemp -d)
java -cp "$CP" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler -no-stdlib -no-reflect -cp "$STD" -d "$OUT" \
  stubs/*.kt Guard.kt "$K/RingGuard.kt" "$K/BootReceiver.kt" "$K/Tombstone.kt" 2>&1 | grep -v "^warning" || true
java -cp "$OUT:$STD" GuardKt
