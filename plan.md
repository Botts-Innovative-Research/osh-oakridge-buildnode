1. **Understand the problem**:
   - WebSocket authentication fails for MQTT streams in the frontend, despite HTTP requests working.
   - We need to add logging to `HttpServer.java` and `OshLoginService.java` to trace the `getBridgedUser` logic and see why it returns `null` for WebSockets.

2. **Add Logging to `OshLoginService.java`**:
   - In `getBridgedUser`, log the `cookieHeader` and local session ID.
   - Log if a bridged user is found or not.

3. **Compile and build**:
   - Run `./gradlew :sensorhub-core:build` to compile `osh-core`.

4. **Instruct User**:
   - Ask the user to run the build with the new logging and capture the output.
