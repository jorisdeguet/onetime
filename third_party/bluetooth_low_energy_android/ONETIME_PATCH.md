# bluetooth_low_energy_android 6.2.1, patched for OneTime

Copied from pub.dev and used through `dependency_overrides` in `pubspec.yaml`.

One change, in `CentralManagerImpl.onConnectionStateChange`: the central asks
for `CONNECTION_PRIORITY_HIGH` once connected. Without it, Android switches to
its balanced connection interval a few seconds after connecting and Bluetooth
key transfers slow down to almost nothing with older phones (no Data Length
Extension, e.g. REVVL 2). Drop this copy if the plugin ever exposes
`requestConnectionPriority`.
