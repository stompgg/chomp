"""
Scans Solidity deploy scripts to extract interface -> concrete class mappings.

Looks for patterns like:
- new ContractName(..., IEffect(vm.envAddress("ENV_VAR")), ...)
- ContractName concreteVar = new ContractName(...)
"""

import re
from pathlib import Path
from typing import Dict, Set, List, Tuple, Optional


class DeployScriptScanner:
    """Scans deploy scripts to infer interface -> concrete mappings."""

    def __init__(self, script_dir: str):
        self.script_dir = Path(script_dir)
        # Maps env var name -> concrete class (e.g., "FROSTBITE_STATUS" -> "FrostbiteStatus")
        self.env_to_concrete: Dict[str, str] = {}
        # Maps (contract_name, param_index) -> concrete class
        self.constructor_mappings: Dict[Tuple[str, int], str] = {}
        # Set of known concrete classes from the scripts
        self.known_concretes: Set[str] = set()

    def scan(self) -> None:
        """Scan all .sol files in the script directory."""
        if not self.script_dir.exists():
            return

        for sol_file in self.script_dir.glob("**/*.sol"):
            self._scan_file(sol_file)

    def _scan_file(self, file_path: Path) -> None:
        """Scan a single deploy script file."""
        try:
            content = file_path.read_text()
        except Exception:
            return

        # Extract concrete class deployments and their env names
        self._extract_deployments(content)

        # Extract constructor calls with interface casts
        self._extract_constructor_calls(content)

    def _extract_deployments(self, content: str) -> None:
        """
        Extract patterns like:
        ConcreteClass varName = new ConcreteClass(...);
        deployedContracts.push(DeployData({name: "ENV NAME", ...}));
        """
        # Pattern: ClassName varName = new ClassName(...)
        # Followed by deployedContracts.push(DeployData({name: "NAME", ...}))

        deploy_pattern = re.compile(
            r'(\w+)\s+\w+\s*=\s*new\s+\1\s*\([^)]*\);\s*'
            r'deployedContracts\.push\(DeployData\(\{name:\s*"([^"]+)"',
            re.MULTILINE
        )

        for match in deploy_pattern.finditer(content):
            concrete_class = match.group(1)
            deploy_name = match.group(2)

            # Convert "FROSTBITE STATUS" to "FROSTBITE_STATUS"
            env_name = deploy_name.upper().replace(" ", "_")

            self.env_to_concrete[env_name] = concrete_class
            self.known_concretes.add(concrete_class)

    def _extract_constructor_calls(self, content: str) -> None:
        """
        Extract patterns like:
        new ContractName(..., IInterface(vm.envAddress("ENV_VAR")), ...)

        Maps (ContractName, param_index) -> concrete class from env var.
        """
        # Pattern: new ClassName(args)
        constructor_pattern = re.compile(
            r'new\s+(\w+)\s*\(([^;]+)\);',
            re.MULTILINE | re.DOTALL
        )

        for match in constructor_pattern.finditer(content):
            contract_name = match.group(1)
            args_str = match.group(2)

            # Parse arguments to find interface casts with vm.envAddress
            self._parse_constructor_args(contract_name, args_str)

    def _parse_constructor_args(self, contract_name: str, args_str: str) -> None:
        """Parse constructor arguments to extract interface -> env var mappings."""
        # Pattern: IInterface(vm.envAddress("ENV_VAR"))
        interface_cast_pattern = re.compile(
            r'I\w+\s*\(\s*vm\.envAddress\s*\(\s*"([^"]+)"\s*\)\s*\)'
        )

        # Split args by comma (rough, but works for most cases)
        # We need to be careful about nested parentheses
        args = self._split_args(args_str)

        for idx, arg in enumerate(args):
            match = interface_cast_pattern.search(arg)
            if match:
                env_var = match.group(1)
                # Try to resolve the env var to a concrete class
                concrete = self._resolve_env_var(env_var)
                if concrete:
                    self.constructor_mappings[(contract_name, idx)] = concrete

    def _split_args(self, args_str: str) -> List[str]:
        """Split comma-separated arguments, respecting nested parentheses."""
        args = []
        current = []
        depth = 0

        for char in args_str:
            if char == '(':
                depth += 1
                current.append(char)
            elif char == ')':
                depth -= 1
                current.append(char)
            elif char == ',' and depth == 0:
                args.append(''.join(current).strip())
                current = []
            else:
                current.append(char)

        if current:
            args.append(''.join(current).strip())

        return args

    def _resolve_env_var(self, env_var: str) -> Optional[str]:
        """
        Resolve an env var name to a concrete class.

        First checks the extracted deployments, then falls back to
        converting SCREAMING_CASE to PascalCase.
        """
        # Check if we have an explicit mapping from deployments
        if env_var in self.env_to_concrete:
            return self.env_to_concrete[env_var]

        # Fallback: convert SCREAMING_CASE to PascalCase
        # FROSTBITE_STATUS -> FrostbiteStatus
        return self._screaming_to_pascal(env_var)

    def _screaming_to_pascal(self, name: str) -> str:
        """Convert SCREAMING_CASE to PascalCase."""
        # Split by underscore and capitalize each part
        parts = name.split('_')
        return ''.join(part.capitalize() for part in parts)

    def get_concrete_for_env(self, env_var: str) -> Optional[str]:
        """Get the concrete class for an env var name."""
        return self._resolve_env_var(env_var)

    def get_concrete_for_constructor(
        self, contract_name: str, param_index: int
    ) -> Optional[str]:
        """Get the concrete class for a specific constructor parameter."""
        return self.constructor_mappings.get((contract_name, param_index))

    def get_all_mappings(self) -> Dict[str, str]:
        """Get all env var -> concrete class mappings."""
        return dict(self.env_to_concrete)
