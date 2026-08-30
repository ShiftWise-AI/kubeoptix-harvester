#!/usr/bin/env python3

import os
import re
import shutil
import argparse
import sys
from pathlib import Path

# Patterns for sensitive information
PATTERNS = {
    "CPF": re.compile(r"\b\d{3}\.\d{3}\.\d{3}-\d{2}\b|\b\d{11}\b"),

    "RG": re.compile(
        r"\b\d{1,2}\.?\d{3}\.?\d{3}-?[0-9Xx]\b"
    ),

    "CARTAO_CREDITO": re.compile(
        r"\b(?:\d[ -]*?){13,19}\b"
    ),

    "EMAIL": re.compile(
        r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"
    ),

    "TELEFONE": re.compile(
        r"\b(?:\+55\s?)?(?:\(?\d{2}\)?\s?)?(?:9?\d{4})[- ]?\d{4}\b"
    ),

    "CEP": re.compile(
        r"\b\d{5}-?\d{3}\b"
    ),

    "ENDERECO": re.compile(
        r"\b(?:Rua|R\.|Avenida|Av\.|Travessa|Tv\.|Alameda|Rodovia)\s+[A-Za-zÀ-ÿ0-9\s,.-]{5,100}",
        re.IGNORECASE
    ),

    "TOKEN": re.compile(
        r"\b(?:Bearer\s+)?[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}\.?[A-Za-z0-9_-]*\b"
    ),

    # Headers and token fields (Kubernetes/OpenShift, OAuth/JWT and variants)
    "TOKEN_EXPLICITO": re.compile(
        r"\b(?:authorization|x-auth-token|token|id_token|access_token|refresh_token|"
        r"bearerToken|serviceAccountToken)\s*[:=]\s*[\"']?(?:Bearer\s+)?[A-Za-z0-9._\-+/=]{8,}[\"']?",
        re.IGNORECASE
    ),

    "CHAVE_API": re.compile(
        r"(?:api[_-]?key|apikey|secret|token)\s*[:=]\s*[\"']?[A-Za-z0-9_\-]{8,}[\"']?",
        re.IGNORECASE
    ),

    # Common certificates/secrets in ConfigMap/OpenShift YAML
    "PEM_CERTIFICATE": re.compile(
        r"-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----",
        re.IGNORECASE
    ),

    "PRIVATE_KEY_PEM": re.compile(
        r"-----BEGIN (?:RSA |EC |OPENSSH |)?PRIVATE KEY-----[\s\S]*?-----END (?:RSA |EC |OPENSSH |)?PRIVATE KEY-----",
        re.IGNORECASE
    ),

    "CERTIFICATE_FIELD": re.compile(
        r"\b(?:ca\.crt|tls\.crt|service-ca\.crt|caBundle|certificate|cert)\s*[:=]\s*[\"']?[A-Za-z0-9+/=._\-]{16,}[\"']?",
        re.IGNORECASE
    ),

    # Banking data: agency/account, bank codes, and international identifiers
    "BANKING_DATA": re.compile(
        r"\b(?:agencia|ag\.?|conta|conta[_\s-]?corrente|conta[_\s-]?poupanca|"
        r"banco|codigo[_\s-]?banco|bank[_\s-]?code|iban|swift|bic|pix)"
        r"\s*[:=]\s*[\"']?[A-Za-z0-9.\-/]{3,}[\"']?",
        re.IGNORECASE
    ),

    # IBAN (international bank identifier)
    "IBAN": re.compile(
        r"\b[A-Z]{2}\d{2}[A-Z0-9]{11,30}\b"
    ),

    # SWIFT/BIC (8 or 11 characters)
    "SWIFT_BIC": re.compile(
        r"\b[A-Z]{6}[A-Z0-9]{2}(?:[A-Z0-9]{3})?\b"
    ),

    # Secrets and tokens commonly present in YAML/Kubernetes/Infra
    "INFRA_SECRET": re.compile(
        r"\b(?:password|passwd|pwd|secret|token|clientSecret|accessKey|secretKey|"
        r"authorization|bearerToken|kubeconfig|privateKey|tls\.key|dockerconfigjson)"
        r"\s*[:=]\s*[\"']?[^\s\"']{4,}[\"']?",
        re.IGNORECASE
    ),

}


def mask_sensitive_data(content):
    found = False

    for pattern_name, pattern in PATTERNS.items():
        new_content, count = pattern.subn(f"[{pattern_name}_REMOVIDO]", content)

        if count > 0:
            found = True
            content = new_content

    return content, found


def show_progress(message, current, total):
    spinner = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
    index = current % len(spinner)
    percent = 0 if total == 0 else int((current * 100) / total)
    filled = percent // 5
    empty = 20 - filled
    bar = "█" * filled + "░" * max(0, empty)

    try:
        cols = os.get_terminal_size().columns
    except OSError:
        cols = 80

    suffix = f" |{bar}| {current}/{total} ({percent}%)"
    suffix_colored = f" \033[32m|{bar}|\033[0m {current}/{total} ({percent}%)"
    prefix = f"[{spinner[index]}] "
    max_msg = cols - len(prefix) - len(suffix) - 1

    if max_msg > 3 and len(message) > max_msg:
        message = message[:max_msg - 3] + "..."

    sys.stdout.write(f"\r\033[K{prefix}{message}{suffix_colored}")
    sys.stdout.flush()


def process_file(file_path, backup=False):
    try:
        # Avoid changing binary files when processing directories
        with open(file_path, "rb") as file:
            raw_data = file.read()

        if b"\x00" in raw_data:
            return "[SKIPPED] binary file"

        content = raw_data.decode("utf-8", errors="ignore")

        new_content, found = mask_sensitive_data(content)

        if found:
            if backup:
                shutil.copy2(file_path, f"{file_path}.bak")

            with open(file_path, "w", encoding="utf-8") as file:
                file.write(new_content)

            return f"[MODIFIED] {file_path}"

        return f"[UNCHANGED] {file_path}"

    except Exception as exc:
        return f"[ERROR] {file_path}: {exc}"


def process_directory(directory, backup=False):
    files = []
    for root, _, file_names in os.walk(directory):
        for file_name in file_names:
            if file_name.endswith(".bak"):
                continue
            files.append(os.path.join(root, file_name))

    total = len(files)
    if total == 0:
        show_progress("No files found", 0, 0)
        sys.stdout.write("\n")
        sys.stdout.flush()
        return

    for index, file_path in enumerate(files, start=1):
        show_progress("Processing files", index, total)
        status = process_file(file_path, backup)
        show_progress(status, index, total)

    sys.stdout.write("\n")
    sys.stdout.flush()


def main():
    parser = argparse.ArgumentParser(
        description="Remove sensitive information from files in the provided directory."
    )

    parser.add_argument(
        "directory",
        help="Directory containing the files"
    )

    parser.add_argument(
        "--backup",
        action="store_true",
        help="Create a .bak file before modifying"
    )

    args = parser.parse_args()

    directory = Path(args.directory)

    if not directory.exists():
        print(f"Directory not found: {directory}")
        return

    process_directory(directory, args.backup)


if __name__ == "__main__":
    main()