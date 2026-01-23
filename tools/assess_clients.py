#!/usr/bin/env python3
"""
BitBarrel Client Library Assessment Tool

Comprehensive assessment of all BitBarrel client libraries to evaluate:
- Implementation completeness
- Feature parity across languages
- Code quality metrics
- Example coverage
- Production readiness

Usage:
    ./tools/assess_clients.py           # Full assessment with color
    ./tools/assess_clients.py --json    # Machine-readable JSON output
    ./tools/assess_clients.py --brief   # Brief summary only
    ./tools/assess_clients.py --check <language>  # Check specific client

Supported Languages: Nim, Python, TypeScript, Go, Dart, Zig, C
"""

import os
import sys
import re
import json
import argparse
from pathlib import Path
from typing import Dict, List, Any, Optional


class Colors:
    """ANSI color codes for terminal output"""
    GREEN = '\033[0;32m'
    YELLOW = '\033[1;33m'
    RED = '\033[0;31m'
    BLUE = '\033[0;34m'
    CYAN = '\033[0;36m'
    WHITE = '\033[1;37m'
    GRAY = '\033[0;37m'
    NC = '\033[0m'

    @classmethod
    def disable(cls):
        """Disable colors for non-terminal output"""
        cls.GREEN = cls.YELLOW = cls.RED = cls.BLUE = cls.CYAN = ''
        cls.WHITE = cls.GRAY = cls.NC = ''


class ClientLibrary:
    """Represents a BitBarrel client library for assessment"""

    def __init__(self, name: str, directory: str, main_file: str,
                 protocol_file: Optional[str] = None):
        self.name = name
        self.directory = directory
        self.main_file = main_file
        self.protocol_file = protocol_file
        self.metrics = {}
        self.features = {}
        self.status = "unknown"
        self.completeness = 0

    def assess(self) -> Dict[str, Any]:
        """Perform comprehensive assessment of the client library"""
        if not os.path.exists(self.directory):
            self.status = "missing"
            return self.get_report()

        # Count implementation files
        impl_files = self._count_implementation_files()
        self.metrics['files'] = len(impl_files)

        if len(impl_files) == 0:
            self.status = "empty"
            return self.get_report()

        self.status = "active"

        # Count methods
        self.metrics['methods'] = self._count_methods()

        # Check for features
        all_content = self._get_all_content(impl_files)
        self._check_features(all_content)

        # Check examples
        self.metrics['examples'] = self._count_examples()

        # Calculate completeness
        self.completeness = self._calculate_completeness()

        return self.get_report()

    def _count_implementation_files(self) -> List[Path]:
        """Count implementation files (excluding tests and examples)"""
        extensions = {
            'Nim': ['.nim'],
            'Python': ['.py'],
            'TypeScript': ['.ts'],
            'Go': ['.go'],
            'Dart': ['.dart'],
            'Zig': ['.zig'],
            'C': ['.c', '.h']
        }

        files = []
        dir_path = Path(self.directory)

        if not dir_path.exists():
            return files

        for ext in extensions.get(self.name, []):
            files.extend(dir_path.rglob(f"*{ext}"))

        # Exclude test and example files
        files = [f for f in files if '/test' not in str(f) and '/example' not in str(f)]

        return files

    def _count_methods(self) -> int:
        """Count public methods in the main client file"""
        if not os.path.exists(self.main_file):
            return 0

        with open(self.main_file, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read()

        patterns = {
            'Nim': r'^proc\s+(\w+)\*?\s*\(',
            'Python': r'^\s*def\s+(\w+)\s*\(self',
            'TypeScript': r'public\s+async\s+(\w+)\s*\(',
            'Go': r'^func\s*\(\w+\s+\*?\w+\)\s+(\w+)\s*\(',
            'Dart': r'Future<[^>]+>\s+(\w+)\s*\(',
            'Zig': r'^pub\s+fn\s+(\w+)\s*\(',
            'C': r'BITBARREL_API\s+\w+\s+(\w+)\s*\('
        }

        pattern = patterns.get(self.name, '')
        if not pattern:
            return 0

        matches = re.findall(pattern, content, re.MULTILINE)
        return len([m for m in matches if not m.startswith('_')])

    def _get_all_content(self, files: List[Path]) -> str:
        """Get all content from implementation files"""
        content = ""
        for file in files:
            if file.is_file():
                try:
                    with open(file, 'r', encoding='utf-8', errors='ignore') as f:
                        content += " " + f.read().lower()
                except:
                    pass
        return content

    def _check_features(self, content: str):
        """Check for specific features in the codebase"""
        self.features = {
            'Core KV': 'set' in content and 'get' in content,
            'Pub/Sub': any(word in content for word in ['subscribe', 'publish', 'pubsub']),
            'Range Queries': 'range' in content,
            'Authentication': 'token' in content or 'auth' in content,
            'Error Handling': 'error' in content or 'exception' in content,
            'WebSocket': 'websocket' in content or 'ws:' in content,
            'HTTP': 'http' in content or 'request' in content,
            'Compression': 'compress' in content
        }

    def _count_examples(self) -> int:
        """Count example files"""
        base_dir = f"clients/{self.name.lower()}"
        if not os.path.exists(base_dir):
            return 0

        example_files = list(Path(base_dir).rglob("*example*")) + \
                       list(Path(base_dir).rglob("*test*"))

        return len([f for f in example_files if f.is_file()])

    def _calculate_completeness(self) -> int:
        """Calculate percentage completeness"""
        if len(self.features) == 0:
            return 0

        enabled = sum(1 for v in self.features.values() if v)
        return int(enabled / len(self.features) * 100)

    def get_report(self) -> Dict[str, Any]:
        """Get assessment report"""
        return {
            'name': self.name,
            'status': self.status,
            'metrics': self.metrics,
            'features': self.features,
            'completeness': self.completeness
        }

    def get_grade(self) -> str:
        """Get implementation grade"""
        if self.completeness >= 80:
            return f"{Colors.GREEN}🌟 FULLY IMPLEMENTED{Colors.NC}"
        elif self.completeness >= 50:
            return f"{Colors.YELLOW}📦 PARTIALLY IMPLEMENTED{Colors.NC}"
        elif self.completeness > 0:
            return f"{Colors.RED}🔨 MINIMAL IMPLEMENTATION{Colors.NC}"
        else:
            return f"{Colors.RED}🚨 MISSING{Colors.NC}"


class AssessmentTool:
    """Main assessment tool orchestrator"""

    def __init__(self, output_format: str = "table", colors: bool = True):
        self.output_format = output_format
        self.colors = colors and sys.stdout.isatty()

        if not self.colors:
            Colors.disable()

        self.clients = self._initialize_clients()

    def _initialize_clients(self) -> List[ClientLibrary]:
        """Initialize all client libraries for assessment"""
        configs = [
            ("Nim", "clients/nim/src/bitbarrel_client", "clients/nim/src/bitbarrel_client/client.nim"),
            ("Python", "clients/python/bitbarrel", "clients/python/bitbarrel/client.py"),
            ("TypeScript", "clients/typescript/src", "clients/typescript/src/client.ts"),
            ("Go", "clients/go", "clients/go/client.go"),
            ("Dart", "clients/dart/lib/src", "clients/dart/lib/src/client.dart"),
            ("Zig", "clients/zig/src", "clients/zig/src/client.zig"),
            ("C", "clients/c/src", "clients/c/include/bitbarrel.h")
        ]

        clients = []
        for name, directory, main_file in configs:
            protocol_file = None
            if name == "Nim":
                protocol_file = "clients/nim/src/bitbarrel_client/protocol.nim"
            elif name == "Python":
                protocol_file = "clients/python/bitbarrel/protocol.py"
            elif name == "TypeScript":
                protocol_file = "clients/typescript/src/protocol.ts"
            elif name == "Go":
                protocol_file = "clients/go/protocol.go"
            elif name == "Dart":
                protocol_file = "clients/dart/lib/src/types.dart"
            elif name == "Zig":
                protocol_file = "clients/zig/src/protocol.zig"
            elif name == "C":
                protocol_file = "clients/c/src/protocol.h"

            clients.append(ClientLibrary(name, directory, main_file, protocol_file))

        return clients

    def run_assessment(self) -> List[Dict[str, Any]]:
        """Run assessment for all client libraries"""
        reports = []

        for client in self.clients:
            report = client.assess()
            reports.append(report)

        return reports

    def print_table(self, reports: List[Dict[str, Any]]):
        """Print assessment results as a table"""
        print(f"\n{Colors.CYAN}╔════════════════════════════════════════════════════════════════════╗{Colors.NC}")
        print(f"{Colors.CYAN}║         BITBARREL CLIENT LIBRARY ASSESSMENT                        ║{Colors.NC}")
        print(f"{Colors.CYAN}╚════════════════════════════════════════════════════════════════════╝{Colors.NC}")
        print()

        # Table header
        print(f"{Colors.BLUE}%-12s %-8s %-8s %-10s %-10s %-10s %-10s{Colors.NC}" %
              ("Language", "Files", "Methods", "Core KV", "Pub/Sub", "Examples", "Complete"))
        print(f"{Colors.GRAY}%s{Colors.NC}" % ("─" * 77))

        # Table rows
        for report in reports:
            client = next(c for c in self.clients if c.name == report['name'])

            color = Colors.GREEN if report['completeness'] >= 80 else \
                   Colors.YELLOW if report['completeness'] >= 50 else \
                   Colors.RED

            print(f"{color}%-12s{Colors.NC} "
                  f"%-8d %-8d %-10s %-10s %-10d %-9s{Colors.NC}" % (
                      report['name'],
                      report['metrics'].get('files', 0),
                      report['metrics'].get('methods', 0),
                      '✓' if report['features'].get('Core KV') else '✗',
                      '✓' if report['features'].get('Pub/Sub') else '✗',
                      report['metrics'].get('examples', 0),
                      f"{report['completeness']}%"
                  ))

        print()

    def print_brief(self, reports: List[Dict[str, Any]]):
        """Print brief summary"""
        print(f"\n{Colors.CYAN}BitBarrel Client Libraries - Brief Summary{Colors.NC}")
        print(f"{Colors.GRAY}%s{Colors.NC}" % ("─" * 50))

        for report in reports:
            status = f"{Colors.GREEN}✓{Colors.NC}" if report['status'] == 'active' else f"{Colors.RED}✗{Colors.NC}"
            print(f"{status} {report['name']}: {report['completeness']}% complete")

        print()

    def print_detailed(self, reports: List[Dict[str, Any]]):
        """Print detailed assessment for each client"""
        for report in reports:
            print(f"\n{Colors.CYAN}{'='*70}{Colors.NC}")
            print(f"{Colors.CYAN}{report['name']} CLIENT LIBRARY{Colors.NC}")
            print(f"{Colors.CYAN}{'='*70}{Colors.NC}")

            client = next(c for c in self.clients if c.name == report['name'])
            print(f"\n{Colors.BLUE}Status:{Colors.NC} {client.get_grade()}")

            print(f"\n{Colors.BLUE}Metrics:{Colors.NC}")
            print(f"  Files: {report['metrics'].get('files', 0)}")
            print(f"  Methods: {report['metrics'].get('methods', 0)}")
            print(f"  Examples: {report['metrics'].get('examples', 0)}")
            print(f"  Completeness: {report['completeness']}%")

            print(f"\n{Colors.BLUE}Feature Support:{Colors.NC}")
            for feature, supported in report['features'].items():
                status = f"{Colors.GREEN}✓{Colors.NC}" if supported else f"{Colors.RED}✗{Colors.NC}"
                print(f"  {status} {feature}")

            print()

    def print_summary(self, reports: List[Dict[str, Any]]):
        """Print overall summary"""
        total = len(reports)
        active = len([r for r in reports if r['status'] == 'active'])
        full = len([r for r in reports if r['completeness'] >= 80])
        partial = len([r for r in reports if 50 <= r['completeness'] < 80])
        missing = total - active

        print(f"\n{C.COLOR}{'='*60}{Colors.NC}")
        print(f"{Colors.CYAN}SUMMARY{C.OLORS.NC}")
        print(f"{Colors.GRAY}{'='*60}{Colors.NC}")

        print(f"Total client libraries: {Colors.WHITE}{total}{Colors.NC}")
        print(f"Fully implemented: {Colors.GREEN}{full}{Colors.NC}")
        print(f"Partially implemented: {Colors.YELLOW}{partial}{Colors.NC}")
        print(f"Missing/empty: {Colors.RED}{missing}{Colors.NC}")

        # Feature coverage
        features = ['Core KV', 'Pub/Sub', 'Range Queries', 'Authentication', 'Error Handling']
        print(f"\n{Colors.BLUE}Feature Coverage:{Colors.NC}")
        for feature in features:
            coverage = sum(1 for r in reports if r['features'].get(feature, False))
            pct = int(coverage / total * 100)
            print(f"  {feature}: {Colors.GREEN}{pct}%{Colors.NC}")

        print()

    def print_json(self, reports: List[Dict[str, Any]]):
        """Print assessment as JSON"""
        output = {
            'summary': {
                'total_clients': len(reports),
                'fully_implemented': sum(1 for r in reports if r['completeness'] >= 80),
                'partially_implemented': sum(1 for r in reports if 50 <= r['completeness'] < 80),
                'missing': sum(1 for r in reports if r['status'] != 'active')
            },
            'clients': reports
        }

        print(json.dumps(output, indent=2))


def main():
    parser = argparse.ArgumentParser(
        description='Assess BitBarrel client library implementations',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s                    # Full assessment with color
  %(prog)s --json            # Machine-readable JSON output
  %(prog)s --brief           # Brief summary only
  %(prog)s --detailed        # Show all details
  %(prog)s --check python    # Check specific client
        """
    )

    parser.add_argument('--json', action='store_true',
                        help='Output as JSON')
    parser.add_argument('--brief', action='store_true',
                        help='Brief summary only')
    parser.add_argument('--detailed', action='store_true',
                        help='Detailed assessment for each client')
    parser.add_argument('--no-color', action='store_true',
                        help='Disable colored output')
    parser.add_argument('--check', metavar='LANGUAGE',
                        choices=['nim', 'python', 'typescript', 'go', 'dart', 'zig', 'c'],
                        help='Check specific client language')

    args = parser.parse_args()

    # Determine output format
    if args.json:
        output_format = "json"
    elif args.brief:
        output_format = "brief"
    elif args.detailed:
        output_format = "detailed"
    else:
        output_format = "table"

    # Create and run assessment tool
    tool = AssessmentTool(output_format, colors=not args.no_color)
    reports = tool.run_assessment()

    # Filter for specific client if requested
    if args.check:
        reports = [r for r in reports if r['name'].lower() == args.check]

    # Print results
    if output_format == "json":
        tool.print_json(reports)
    elif output_format == "brief":
        tool.print_brief(reports)
    elif output_format == "detailed":
        tool.print_detailed(reports)
    else:
        tool.print_table(reports)
        tool.print_summary(reports)

    # Exit with error if any clients are missing
    failed = len([r for r in reports if r['status'] != 'active'])
    sys.exit(1 if failed > 0 else 0)


if __name__ == "__main__":
    main()
