#!/usr/bin/env bash
# KitoAi security tools installer (Kali/Debian/Ubuntu or Windows Git-Bash).
set -euo pipefail

TOOLS=(nmap subfinder httpx nuclei katana ffuf sqlmap nikto)

is_mingw() { [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* ]]; }

install_go_tool() {
  local pkg="$1"
  echo "[*] installing $pkg via go install..."
  command -v go >/dev/null 2>&1 || { echo "[!] go not found — install Go first: https://go.dev/dl/"; return 1; }
  go install "$pkg"@latest
  local gopath="${GOPATH:-$HOME/go}/bin"
  echo "[+] $pkg -> $gopath (add to PATH)"
}

install_apt() { sudo apt-get update -y && sudo apt-get install -y nmap ffuf sqlmap nikto; }
install_choco() { choco install -y nmap ffuf sqlmap; }

main() {
  if is_mingw; then
    echo "[*] Windows detected — using go install + choco where possible."
    command -v choco >/dev/null 2>&1 && install_choco || echo "[!] choco missing; install nmap/ffuf manually."
  else
    echo "[*] Linux detected — installing via apt."
    install_apt
  fi

  install_go_tool github.com/projectdiscovery/subfinder/v2/cmd/subfinder || true
  install_go_tool github.com/projectdiscovery/httpx/cmd/httpx || true
  install_go_tool github.com/projectdiscovery/nuclei/v3/cmd/nuclei || true
  install_go_tool github.com/projectdiscovery/katana/cmd/katana || true
  install_go_tool github.com/ffuf/ffuf/v2 || true

  echo
  echo "[*] Done. Verify with:"
  for t in "${TOOLS[@]}"; do
    command -v "$t" >/dev/null 2>&1 && echo "    $t: OK" || echo "    $t: missing (see hints above)"
  done
}

main
