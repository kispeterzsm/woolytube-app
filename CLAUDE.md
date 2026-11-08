## Clean up build programs and temp files when done
This machine has only 7.5 GB of RAM, and `/tmp` is a RAM-backed tmpfs.

- **Stop daemons:** when a task or workflow is finished, stop the build daemons it left running: the Gradle daemon (`GradleDaemon`), the Kotlin compile daemon (`KotlinCompileDaemon`), and stray `flutter_tools`/`dart` test processes. They hold several GB including swap, and they restart on their own at the next build.
  - Find them with `ps -eo pid,etime,rss,cmd --sort=-rss | grep -E 'java|gradle|kotlin|dart|flutter'`.
  - Stop them by PID after checking the command line.
- **Keep:** don't kill the `adb` server, which the phone connection needs.
- **Temp files:** delete large test files (audio decodes, file copies, leftover `/tmp/flutter_tools.*` folders) from the scratchpad and `/tmp` once they're no longer needed, since they use RAM.
- **Workflows:** tell workflow agents to do the same before they finish.
