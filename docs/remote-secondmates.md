# Remote secondmates

Remote secondmate agent launch is currently unsupported. The remote control entrypoint refuses `launch` because none of the supported session backends provides the always-on remote endpoint required to survive SSH disconnects. Existing remote homes can still be inspected, synchronized, updated, or retired through the host-local maintenance commands.

The SSH provisioning and doctor scaffolding remains available for maintaining registered homes. It does not imply that a remote agent can be launched. `bin/fm-remote-secondmate-control.sh` owns the current command behavior, and `bin/fm-remote-doctor.sh` owns readiness checks.

A future remote launch implementation must use a supported backend and prove endpoint liveness and recovery across SSH disconnects before enabling the launch path.
