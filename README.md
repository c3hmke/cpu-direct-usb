# CPU Direct USB

USB latency analyzer that counts chips between your input devices and the CPU. Fewer chips = lower latency.

## Quick Start

### Run in PowerShell:

```powershell
irm https://tools.mariusheier.com/cpudirect.ps1 | iex
```

### Run in bash:

```bash
curl -fsSL https://tools.mariusheier.com/cpudirect.bash | bash
```
or
```bash
wget -qO- https://tools.mariusheier.com/cpudirect.bash | bash
```

## What It Shows

- **CHIP 0**: Device connects directly to CPU (lowest latency)
- **CHIP 1**: Device goes through chipset (adds latency)
- **CHIP 2+**: Device goes through USB hub(s) (more latency)

## Features

- Identifies all USB input devices (mice, keyboards, controllers)
- Shows USB controller topology (Intel/AMD CPU-integrated vs chipset)
- Detects MSI interrupt status
- Identifies USB hubs in the path
- Suggests optimizations (disable selective suspend, enable MSI)

## Verification

All releases include SHA256 checksums. To verify:

Powershell:
```powershell
(Get-FileHash cpudirect.ps1 -Algorithm SHA256).Hash
```

bash:
```bash
sha256sum cpudirect.bash
```


Compare with the checksum in the [release notes](https://github.com/MariusHeier/cpu-direct-usb/releases).

## License

MIT
