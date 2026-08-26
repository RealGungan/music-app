/// Stamp injected at build time via:
///   flutter build linux --dart-define=BUILD_ID=<utc timestamp>
const String kBuildId = String.fromEnvironment(
  'BUILD_ID',
  defaultValue: 'dev',
);
