# Vendored: McBopomofo (MIT)

- Source: https://github.com/openvanilla/McBopomofo @ 18e2060dd5d0b511753ad79a8fe0d112e944f1af
- Data (`Keyboard/Resources/data.txt`, `associated-phrases-v2.txt`): taken from the
  official release McBopomofo-Installer-3.1.1.zip (inner McBopomofo-r2510.zip),
  not rebuilt locally.
- Only `Source/Engine` is compiled (tests, benchmarks and EngineProfile excluded).

## Local patch

`Source/Engine/UserOverrideModel.h`: `observe(const std::string& key, …)` made
`virtual` (plus a virtual destructor) so `JournalingUserOverrideModel` in
`Keyboard/Engine/ZhuyinEngine.mm` can journal every learned override to the App
Group and replay it on launch. Upstream keeps the model in memory only, which a
keyboard extension (killed often) would lose.

The same change as a diff: `mcbopomofo-local.patch` (apply on top of the commit above).
