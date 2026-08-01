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
    "CERTIFICADO_PEM": re.compile(
        r"-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----",
        re.IGNORECASE
    ),

    "CHAVE_PRIVADA_PEM": re.compile(
        r"-----BEGIN (?:RSA |EC |OPENSSH |)?PRIVATE KEY-----[\s\S]*?-----END (?:RSA |EC |OPENSSH |)?PRIVATE KEY-----",
        re.IGNORECASE
    ),

    "CAMPO_CERTIFICADO": re.compile(
        r"\b(?:ca\.crt|tls\.crt|service-ca\.crt|caBundle|certificate|cert)\s*[:=]\s*[\"']?[A-Za-z0-9+/=._\-]{16,}[\"']?",
        re.IGNORECASE
    ),

    # Banking data: agency/account, bank codes, and international identifiers
    "DADOS_BANCARIOS": re.compile(
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
    "SEGREDO_INFRA": re.compile(
        r"\b(?:password|passwd|pwd|secret|token|clientSecret|accessKey|secretKey|"
        r"authorization|bearerToken|kubeconfig|privateKey|tls\.key|dockerconfigjson)"
        r"\s*[:=]\s*[\"']?[^\s\"']{4,}[\"']?",
        re.IGNORECASE
    ),

}


def mascarar_dados(conteudo):
    encontrou = False

    for tipo, pattern in PATTERNS.items():
        novo_conteudo, qtd = pattern.subn(f"[{tipo}_REMOVIDO]", conteudo)

        if qtd > 0:
            encontrou = True
            conteudo = novo_conteudo

    return conteudo, encontrou


def mostrar_progresso(message, current, total):
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


def processar_arquivo(arquivo, backup=False):
    try:
        # Avoid changing binary files when processing directories
        with open(arquivo, "rb") as f:
            bruto = f.read()

        if b"\x00" in bruto:
            return "[SKIPPED] binary file"

        conteudo = bruto.decode("utf-8", errors="ignore")

        novo_conteudo, encontrou = mascarar_dados(conteudo)

        if encontrou:
            if backup:
                shutil.copy2(arquivo, f"{arquivo}.bak")

            with open(arquivo, "w", encoding="utf-8") as f:
                f.write(novo_conteudo)

            return f"[MODIFIED] {arquivo}"

        return f"[UNCHANGED] {arquivo}"

    except Exception as e:
        return f"[ERROR] {arquivo}: {e}"


def processar_diretorio(diretorio, backup=False):
    arquivos = []
    for raiz, _, nomes_arquivos in os.walk(diretorio):
        for nome_arquivo in nomes_arquivos:
            if nome_arquivo.endswith(".bak"):
                continue
            arquivos.append(os.path.join(raiz, nome_arquivo))

    total = len(arquivos)
    if total == 0:
        mostrar_progresso("No files found", 0, 0)
        sys.stdout.write("\n")
        sys.stdout.flush()
        return

    for index, caminho in enumerate(arquivos, start=1):
        mostrar_progresso("Processing files", index, total)
        status = processar_arquivo(caminho, backup)
        mostrar_progresso(status, index, total)

    sys.stdout.write("\n")
    sys.stdout.flush()


def main():
    parser = argparse.ArgumentParser(
        description="Remove sensitive information from files in the provided directory."
    )

    parser.add_argument(
        "diretorio",
        help="Directory containing the files"
    )

    parser.add_argument(
        "--backup",
        action="store_true",
        help="Create a .bak file before modifying"
    )

    args = parser.parse_args()

    diretorio = Path(args.diretorio)

    if not diretorio.exists():
        print(f"Directory not found: {diretorio}")
        return

    processar_diretorio(diretorio, args.backup)


if __name__ == "__main__":
    main()