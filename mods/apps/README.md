# apps/

Drop APK files here to bake them into the system partition.

| Folder | Ends up at | Use for |
|---|---|---|
| `apps/system/Foo.apk` | `/system/app/Foo/Foo.apk` | normal system apps |
| `apps/priv-app/Foo.apk` | `/system/priv-app/Foo/Foo.apk` | apps that need privileged permissions |

Rules:
- Only add APKs you trust and are allowed to redistribute.
- The APK must match the image's CPU: the test emulator is **x86_64**, the GSI is **arm64**.
  Pure Java/Kotlin APKs work on both.
- A priv-app that asks for privileged permissions also needs a whitelist file, or the
  phone will not boot. Put it in `overlay/etc/permissions/privapp-permissions-<package>.xml`.
- Keep APKs small; git is not great with big binaries (GitHub blocks files over 100 MB).
