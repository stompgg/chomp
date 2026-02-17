#!/usr/bin/env python3
"""
Script to parse DeployData output from forge scripts and convert to env format.

Modes:
  --parse: Read from stdin and output parsed KEY=VALUE lines to stdout (no file I/O)
  (default): Read from processing/input.txt and write to processing/output.txt
"""

import argparse
import re
import sys


def parse_deploy_data_array(content):
    """Parse the DeployData array structure from the input content"""
    # Remove whitespace and newlines
    content = content.strip()

    # Extract individual DeployData objects using regex
    deploy_data_pattern = r'DeployData\(\{\s*name:\s*"([^"]+)",\s*contractAddress:\s*(0x[a-fA-F0-9]+)\s*\}\)'
    matches = re.findall(deploy_data_pattern, content)

    return matches


def parse_content_to_env_lines(content):
    """Parse content and return list of KEY=VALUE lines"""
    output = []

    deploy_data_matches = parse_deploy_data_array(content)
    if deploy_data_matches:
        for name, address in deploy_data_matches:
            name = name.upper().replace(" ", "_").replace("-", "_")
            output.append(f"{name}={address}")

    return output


def process_file(input_file, output_file):
    with open(input_file, 'r') as f:
        content = f.read()

    output = parse_content_to_env_lines(content)

    with open(output_file, 'w') as f:
        f.write('\n'.join(output))


def main():
    parser = argparse.ArgumentParser(
        description='Parse DeployData output from forge scripts'
    )
    parser.add_argument(
        '--parse',
        action='store_true',
        help='Read from stdin and output parsed KEY=VALUE lines to stdout'
    )
    args = parser.parse_args()

    if args.parse:
        # Read from stdin, parse, output to stdout
        content = sys.stdin.read()
        lines = parse_content_to_env_lines(content)
        for line in lines:
            print(line)
    else:
        # Original file-based mode
        input_file = 'processing/input.txt'
        output_file = 'processing/output.txt'
        process_file(input_file, output_file)
        print(f"Conversion complete. Output written to {output_file}")


if __name__ == "__main__":
    main()