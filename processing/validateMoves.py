#!/usr/bin/env python3
"""
Script to validate move contracts against CSV data.
Checks that contract implementations match the expected values from moves.csv.
"""

import csv
import json
import os
import re
from pathlib import Path
from typing import Dict, List, Optional, Tuple, Any, Union
from dataclasses import dataclass

@dataclass
class MoveData:
    """Data structure for move information from CSV"""
    name: str
    mon: str
    power: Union[int, str]  # Can be int or '?' for complex moves
    stamina: Union[int, str]
    accuracy: Union[int, str]
    priority: Union[int, str]
    move_type: str
    move_class: str
    description: str
    extra_data: str

@dataclass
class ContractData:
    """Data structure for extracted contract information"""
    file_path: str
    power: Optional[int] = None
    stamina: Optional[int] = None
    accuracy: Optional[int] = None
    priority: Optional[int] = None
    move_type: Optional[str] = None
    move_class: Optional[str] = None
    is_standard_attack: bool = False
    is_custom_implementation: bool = False

class MoveValidator:
    """Main validator class for checking move contracts against CSV data"""
    
    # Constants from the codebase
    DEFAULT_PRIORITY = 3
    
    # Type enum mapping
    TYPE_MAPPING = {
        'Yin': 'Type.Yin',
        'Yang': 'Type.Yang', 
        'Earth': 'Type.Earth',
        'Liquid': 'Type.Liquid',
        'Fire': 'Type.Fire',
        'Metal': 'Type.Metal',
        'Ice': 'Type.Ice',
        'Nature': 'Type.Nature',
        'Lightning': 'Type.Lightning',
        'Mythic': 'Type.Mythic',
        'Air': 'Type.Air',
        'Math': 'Type.Math',
        'Cyber': 'Type.Cyber',
        'Wild': 'Type.Wild',
        'Cosmic': 'Type.Cosmic',
        'None': 'Type.None'
    }
    
    # MoveClass enum mapping
    CLASS_MAPPING = {
        'Physical': 'MoveClass.Physical',
        'Special': 'MoveClass.Special',
        'Self': 'MoveClass.Self',
        'Other': 'MoveClass.Other'
    }
    
    def __init__(self, csv_path: str, src_path: str):
        self.csv_path = csv_path
        self.src_path = src_path
        self.moves_data: Dict[str, MoveData] = {}
        self.validation_results: List[Dict[str, Any]] = []

        # Initialize mon-specific parsing rules
        self.mon_specific_rules = self._init_mon_specific_rules()

    def _init_mon_specific_rules(self) -> Dict[str, callable]:
        """Initialize mon-specific parsing rules for complex moves"""
        return {
            'Embursa': self._parse_embursa_moves
        }

    def _parse_embursa_moves(self, content: str, contract_data: ContractData) -> ContractData:
        """Custom parser for Embursa moves. Handles priority overrides that use HeatBeaconLib."""

        # Check if there's a priority function override (for both StandardAttack and IMoveSet)
        priority_pattern = r'function\s+priority\s*\([^)]*\)\s*[^{]*\{\s*return\s+([^;]+);'
        match = re.search(priority_pattern, content, re.DOTALL)

        if match:
            priority_expr = match.group(1).strip()

            # If it uses DEFAULT_PRIORITY (with or without HeatBeaconLib), accept it
            if 'DEFAULT_PRIORITY' in priority_expr:
                contract_data.priority = self.DEFAULT_PRIORITY

        return contract_data

    def normalize_move_name(self, name: str) -> str:
        """Convert move name to CamelCase with spaces and punctuation removed"""
        # Remove punctuation and split on spaces
        words = re.sub(r'[^\w\s]', '', name).split()
        # Convert to CamelCase
        return ''.join(word.capitalize() for word in words)
    
    def _parse_int_or_question(self, value: str) -> Union[int, str]:
        """Parse a value that can be either an integer or '?' for complex moves"""
        if value.strip() == '?':
            return '?'
        return int(value)

    def load_csv_data(self) -> None:
        """Load and parse the moves CSV file"""
        with open(self.csv_path, 'r', encoding='utf-8') as file:
            reader = csv.DictReader(file)
            for row in reader:
                move_data = MoveData(
                    name=row['Name'],
                    mon=row['Mon'],
                    power=self._parse_int_or_question(row['Power']),
                    stamina=self._parse_int_or_question(row['Stamina']),
                    accuracy=self._parse_int_or_question(row['Accuracy']),
                    priority=self._parse_int_or_question(row['Priority']),
                    move_type=row['Type'],
                    move_class=row['Class'],
                    description=row['DevDescription'], # Change to UserDescription later
                    extra_data=row.get('InputType', '')
                )
                normalized_name = self.normalize_move_name(move_data.name)
                self.moves_data[normalized_name] = move_data
    
    def find_move_file(self, move_name: str) -> Optional[str]:
        """Find the move file (.json or .sol) for a given move name"""
        json_name = f"{move_name}.json"
        sol_name = f"{move_name}.sol"

        # Search recursively through src directory, preferring .json
        for root, dirs, files in os.walk(self.src_path):
            if json_name in files:
                return os.path.join(root, json_name)
        for root, dirs, files in os.walk(self.src_path):
            if sol_name in files:
                return os.path.join(root, sol_name)

        return None

    def parse_json_move(self, file_path: str) -> ContractData:
        """Parse a JSON inline move definition"""
        contract_data = ContractData(file_path=file_path)
        contract_data.is_standard_attack = True  # JSON moves are inline StandardAttacks

        with open(file_path, 'r', encoding='utf-8') as f:
            data = json.load(f)

        contract_data.power = data.get('basePower')
        contract_data.stamina = data.get('staminaCost')
        contract_data.accuracy = 100  # JSON moves always use DEFAULT_ACCURACY
        contract_data.move_type = data.get('moveType')
        contract_data.move_class = data.get('moveClass')

        # Priority: JSON stores offset from DEFAULT_PRIORITY, convert to absolute
        # (JSON has no priority field = offset 0 = DEFAULT_PRIORITY)
        contract_data.priority = self.DEFAULT_PRIORITY

        return contract_data

    def parse_contract_file(self, file_path: str, mon_name: str = None) -> ContractData:
        """Parse a Solidity contract file to extract move data"""
        contract_data = ContractData(file_path=file_path)

        with open(file_path, 'r', encoding='utf-8') as file:
            content = file.read()

        # Check if it inherits from StandardAttack
        if 'StandardAttack' in content and 'is StandardAttack' in content:
            contract_data.is_standard_attack = True
            contract_data = self._parse_standard_attack(content, contract_data)
        elif 'IMoveSet' in content and 'is IMoveSet' in content:
            contract_data.is_custom_implementation = True
            contract_data = self._parse_custom_implementation(content, contract_data)

        # Apply mon-specific parsing rules after standard parsing (allows overrides)
        if mon_name and mon_name in self.mon_specific_rules:
            custom_parser = self.mon_specific_rules[mon_name]
            contract_data = custom_parser(content, contract_data)

        return contract_data

    def _parse_standard_attack(self, content: str, contract_data: ContractData) -> ContractData:
        """Parse StandardAttack constructor parameters"""
        # Find ATTACK_PARAMS block
        attack_params_match = re.search(r'ATTACK_PARAMS\s*\(\s*\{([^}]+)\}\s*\)', content, re.DOTALL)
        if not attack_params_match:
            return contract_data

        params_block = attack_params_match.group(1)

        # Extract individual parameters
        contract_data.power = self._extract_param_value(params_block, 'BASE_POWER')
        contract_data.stamina = self._extract_param_value(params_block, 'STAMINA_COST')
        contract_data.accuracy = self._extract_param_value(params_block, 'ACCURACY')
        contract_data.priority = self._extract_priority_value(params_block)
        contract_data.move_type = self._extract_enum_value(params_block, 'MOVE_TYPE', 'Type')
        contract_data.move_class = self._extract_enum_value(params_block, 'MOVE_CLASS', 'MoveClass')

        return contract_data

    def _parse_custom_implementation(self, content: str, contract_data: ContractData) -> ContractData:
        """Parse custom IMoveSet implementation"""
        # Look for constant declarations
        contract_data.power = self._extract_constant_value(content, 'BASE_POWER')

        # Look for accuracy constant (try both DEFAULT_ACCURACY and ACCURACY)
        contract_data.accuracy = self._extract_constant_value(content, 'DEFAULT_ACCURACY')
        if contract_data.accuracy is None:
            contract_data.accuracy = self._extract_constant_value(content, 'ACCURACY')

        # Look for function implementations
        contract_data.stamina = self._extract_function_return_value(content, 'stamina')
        contract_data.priority = self._extract_function_return_value(content, 'priority')
        contract_data.move_type = self._extract_function_enum_return(content, 'moveType', 'Type')
        contract_data.move_class = self._extract_function_enum_return(content, 'moveClass', 'MoveClass')

        return contract_data

    def _extract_param_value(self, params_block: str, param_name: str) -> Optional[int]:
        """Extract numeric parameter value from ATTACK_PARAMS block"""
        pattern = rf'{param_name}:\s*(\d+)'
        match = re.search(pattern, params_block)
        return int(match.group(1)) if match else None

    def _extract_priority_value(self, params_block: str) -> Optional[int]:
        """Extract priority value, handling DEFAULT_PRIORITY expressions"""
        pattern = r'PRIORITY:\s*([^,\n]+)'
        match = re.search(pattern, params_block)
        if not match:
            return None

        priority_expr = match.group(1).strip()

        # Handle DEFAULT_PRIORITY expressions
        if 'DEFAULT_PRIORITY' in priority_expr:
            return self._evaluate_priority_expression(priority_expr)

        # Try to parse as direct number
        try:
            return int(priority_expr)
        except ValueError:
            return None

    def _evaluate_priority_expression(self, expr: str) -> Optional[int]:
        """Evaluate arithmetic expressions involving DEFAULT_PRIORITY"""
        # Replace DEFAULT_PRIORITY with its actual value
        expr_with_value = expr.replace('DEFAULT_PRIORITY', str(self.DEFAULT_PRIORITY))

        # Remove whitespace
        expr_with_value = expr_with_value.replace(' ', '')

        # Validate that the expression only contains safe characters
        if not re.match(r'^[\d+\-*/()]+$', expr_with_value):
            return None

        try:
            # Safely evaluate the arithmetic expression
            return int(eval(expr_with_value))
        except (ValueError, SyntaxError, ZeroDivisionError):
            return None

    def _extract_enum_value(self, params_block: str, param_name: str, enum_type: str) -> Optional[str]:
        """Extract enum parameter value from ATTACK_PARAMS block"""
        pattern = rf'{param_name}:\s*{enum_type}\.(\w+)'
        match = re.search(pattern, params_block)
        return match.group(1) if match else None

    def _extract_constant_value(self, content: str, constant_name: str) -> Optional[int]:
        """Extract constant value from contract"""
        pattern = rf'{constant_name}\s*=\s*(\d+)'
        match = re.search(pattern, content)
        return int(match.group(1)) if match else None

    def _extract_function_return_value(self, content: str, function_name: str) -> Optional[int]:
        """Extract return value from function implementation"""
        # Look for function that returns a constant
        pattern = rf'function\s+{function_name}\s*\([^)]*\)\s*[^{{]*\{{\s*return\s+(\d+);'
        match = re.search(pattern, content, re.DOTALL)
        if match:
            return int(match.group(1))

        # Look for function that returns a constant variable or expression
        pattern = rf'function\s+{function_name}\s*\([^)]*\)\s*[^{{]*\{{\s*return\s+([^;]+);'
        match = re.search(pattern, content, re.DOTALL)
        if match:
            return_expr = match.group(1).strip()

            # Handle known constants
            if return_expr == 'DEFAULT_PRIORITY':
                return self.DEFAULT_PRIORITY
            elif 'DEFAULT_PRIORITY' in return_expr:
                return self._evaluate_priority_expression(return_expr)

            # Try to extract as local constant
            if re.match(r'^[A-Z_]+$', return_expr):
                local_value = self._extract_constant_value(content, return_expr)
                if local_value is not None:
                    return local_value

            # Try to parse as direct number
            try:
                return int(return_expr)
            except ValueError:
                pass

        return None

    def _extract_function_enum_return(self, content: str, function_name: str, enum_type: str) -> Optional[str]:
        """Extract enum return value from function implementation"""
        pattern = rf'function\s+{function_name}\s*\([^)]*\)\s*[^{{]*\{{\s*return\s+{enum_type}\.(\w+);'
        match = re.search(pattern, content, re.DOTALL)
        return match.group(1) if match else None

    def csv_priority_to_contract_priority(self, csv_priority: int) -> int:
        """Convert CSV priority (0-based) to contract priority (DEFAULT_PRIORITY-based)"""
        return self.DEFAULT_PRIORITY + csv_priority

    def validate_move(self, move_name: str, move_data: MoveData, contract_data: ContractData) -> Dict[str, Any]:
        """Validate a single move against its contract"""
        result = {
            'move_name': move_data.name,
            'normalized_name': move_name,
            'contract_file': contract_data.file_path,
            'is_standard_attack': contract_data.is_standard_attack,
            'is_custom_implementation': contract_data.is_custom_implementation,
            'errors': [],
            'warnings': []
        }

        # Skip power validation for 0-power moves or complex moves marked with '?'
        if move_data.power != '?' and isinstance(move_data.power, int) and move_data.power > 0:
            if contract_data.power is None:
                result['errors'].append(f"Power not found in contract (expected: {move_data.power})")
            elif contract_data.power != move_data.power:
                result['errors'].append(f"Power mismatch: contract={contract_data.power}, csv={move_data.power}")
        elif move_data.power == '?':
            result['warnings'].append("Power validation skipped - marked as complex move ('?')")

        # Validate stamina
        if move_data.stamina != '?':
            if contract_data.stamina is None:
                result['errors'].append(f"Stamina not found in contract (expected: {move_data.stamina})")
            elif contract_data.stamina != move_data.stamina:
                result['errors'].append(f"Stamina mismatch: contract={contract_data.stamina}, csv={move_data.stamina}")
        else:
            result['warnings'].append("Stamina validation skipped - marked as complex move ('?')")

        # Validate accuracy (skip if not found in contract)
        if move_data.accuracy != '?' and contract_data.accuracy is not None:
            if contract_data.accuracy != move_data.accuracy:
                result['errors'].append(f"Accuracy mismatch: contract={contract_data.accuracy}, csv={move_data.accuracy}")
        elif move_data.accuracy == '?':
            result['warnings'].append("Accuracy validation skipped - marked as complex move ('?')")

        # Validate priority
        if move_data.priority != '?':
            expected_priority = self.csv_priority_to_contract_priority(move_data.priority)
            if contract_data.priority is None:
                result['errors'].append(f"Priority not found in contract (expected: {expected_priority})")
            elif contract_data.priority != expected_priority:
                result['errors'].append(f"Priority mismatch: contract={contract_data.priority}, csv={move_data.priority} (expected contract value: {expected_priority})")
        else:
            result['warnings'].append("Priority validation skipped - marked as complex move ('?')")

        # Validate move type
        if contract_data.move_type is None:
            result['errors'].append(f"Move type not found in contract (expected: {move_data.move_type})")
        elif contract_data.move_type != move_data.move_type:
            result['errors'].append(f"Move type mismatch: contract={contract_data.move_type}, csv={move_data.move_type}")

        # Validate move class
        if contract_data.move_class is None:
            result['errors'].append(f"Move class not found in contract (expected: {move_data.move_class})")
        elif contract_data.move_class != move_data.move_class:
            result['errors'].append(f"Move class mismatch: contract={contract_data.move_class}, csv={move_data.move_class}")

        return result

    def run_validation(self) -> tuple[bool, bool]:
        """
        Run validation for all moves.

        Returns:
            Tuple of (validation_passed, changes_made):
            - validation_passed: True if no errors were found
            - changes_made: True if user accepted changes and contracts were updated
        """
        self.load_csv_data()
        print(f"Loaded {len(self.moves_data)} moves from CSV")
        found_contracts = 0
        missing_contracts = []

        for move_name, move_data in self.moves_data.items():
            move_file = self.find_move_file(move_name)

            if move_file is None:
                missing_contracts.append((move_name, move_data.name))
                continue

            found_contracts += 1

            # Parse and validate the move (JSON or Solidity)
            if move_file.endswith('.json'):
                contract_data = self.parse_json_move(move_file)
            else:
                contract_data = self.parse_contract_file(move_file, move_data.mon)
            validation_result = self.validate_move(move_name, move_data, contract_data)
            self.validation_results.append(validation_result)

        print(f"\nFound {found_contracts} contracts, {len(missing_contracts)} missing")

        # Report results
        self.print_summary()
        self.print_detailed_errors()

        if missing_contracts:
            self.print_missing_contracts(missing_contracts)

        # Prompt user to update contracts if there are errors
        moves_with_errors = sum(1 for result in self.validation_results if result['errors'])
        if moves_with_errors > 0:
            print("\n" + "="*80)
            response = input("Would you like to update the .sol files with values from the CSV? (y/n): ").strip().lower()
            if response == 'y':
                self.update_all_contracts()
                return (False, True)  # Errors existed, changes were made
            else:
                print("Skipping contract updates.")
                return (False, False)  # Errors existed, no changes made

        return (True, False)  # No errors, no changes needed

    def print_summary(self) -> None:
        """Print a condensed summary of validation results"""
        print("\n" + "="*80)
        print("VALIDATION SUMMARY")
        print("="*80)

        total_moves = len(self.validation_results)
        moves_with_errors = sum(1 for result in self.validation_results if result['errors'])
        moves_with_warnings = sum(1 for result in self.validation_results if result['warnings'])

        standard_attack_count = sum(1 for result in self.validation_results if result['is_standard_attack'])
        custom_implementation_count = sum(1 for result in self.validation_results if result['is_custom_implementation'])

        print(f"Total moves validated: {total_moves}")
        print(f"Moves with errors: {moves_with_errors}")
        print(f"Moves with warnings: {moves_with_warnings}")
        print(f"StandardAttack implementations: {standard_attack_count}")
        print(f"Custom IMoveSet implementations: {custom_implementation_count}")

        if moves_with_errors == 0:
            print("\n✅ All validations passed!")
        else:
            print(f"\n❌ {moves_with_errors} moves have validation errors")

    def print_detailed_errors(self) -> None:
        """Print detailed error information"""
        moves_with_issues = [result for result in self.validation_results
                           if result['errors'] or result['warnings']]

        if not moves_with_issues:
            return

        for result in moves_with_issues:
            if result['errors']:
                print(f"\n📁 File: {result['contract_file']} | ❌ Errors")
                for error in result['errors']:
                    print(f"      • {error}")

    def print_missing_contracts(self, missing_contracts: List[Tuple[str, str]]) -> None:
        """Print information about missing contract files"""
        print("\n" + "="*80)
        print("MISSING CONTRACTS")
        print("="*80)

        for normalized_name, original_name in missing_contracts:
            print(f"❌ {original_name} -> {normalized_name}.sol (not found)")

    def _is_simple_constant_return(self, content: str, function_name: str) -> bool:
        """Check if a function just returns a simple constant (number, enum, or DEFAULT_PRIORITY expression)"""
        pattern = rf'function\s+{function_name}\s*\([^)]*\)\s*[^{{]*\{{\s*return\s+([^;]+);'
        match = re.search(pattern, content, re.DOTALL)
        if not match:
            return False

        return_expr = match.group(1).strip()

        # Check if it's a simple number
        if re.match(r'^\d+$', return_expr):
            return True

        # Check if it's DEFAULT_PRIORITY or DEFAULT_PRIORITY +/- number
        if re.match(r'^DEFAULT_PRIORITY(\s*[+\-]\s*\d+)?$', return_expr):
            return True

        # Check if it's a simple enum (Type.X or MoveClass.X)
        if re.match(r'^(Type|MoveClass)\.\w+$', return_expr):
            return True

        return False

    def update_contract_file(self, result: Dict[str, Any]) -> bool:
        """Update a contract file with CSV values. Returns True if file was modified."""
        if not result['errors']:
            return False

        file_path = result['contract_file']
        move_name = result['normalized_name']
        move_data = self.moves_data[move_name]

        with open(file_path, 'r', encoding='utf-8') as file:
            content = file.read()

        original_content = content
        modified = False

        # Handle StandardAttack contracts
        if result['is_standard_attack']:
            # Find ATTACK_PARAMS block
            attack_params_match = re.search(r'(ATTACK_PARAMS\s*\(\s*\{)([^}]+)(\}\s*\))', content, re.DOTALL)
            if not attack_params_match:
                print(f"  ⚠️  Could not find ATTACK_PARAMS block in {file_path}")
                return False

            params_block = attack_params_match.group(2)
            updated_params = params_block

            # Update power if there's a mismatch and it's not a complex move
            if move_data.power != '?' and isinstance(move_data.power, int) and move_data.power > 0:
                power_pattern = r'(BASE_POWER:\s*)(\d+)'
                if re.search(power_pattern, updated_params):
                    updated_params = re.sub(power_pattern, rf'\g<1>{move_data.power}', updated_params)
                    modified = True

            # Update stamina if there's a mismatch and it's not a complex move
            if move_data.stamina != '?' and isinstance(move_data.stamina, int):
                stamina_pattern = r'(STAMINA_COST:\s*)(\d+)'
                if re.search(stamina_pattern, updated_params):
                    updated_params = re.sub(stamina_pattern, rf'\g<1>{move_data.stamina}', updated_params)
                    modified = True

            # Update accuracy if there's a mismatch and it's not a complex move
            if move_data.accuracy != '?' and isinstance(move_data.accuracy, int):
                accuracy_pattern = r'(ACCURACY:\s*)(\d+)'
                if re.search(accuracy_pattern, updated_params):
                    updated_params = re.sub(accuracy_pattern, rf'\g<1>{move_data.accuracy}', updated_params)
                    modified = True

            # Update priority if there's a mismatch and it's not a complex move
            if move_data.priority != '?' and isinstance(move_data.priority, int):
                expected_priority = self.csv_priority_to_contract_priority(move_data.priority)
                # Handle both direct numbers and DEFAULT_PRIORITY expressions
                priority_pattern = r'(PRIORITY:\s*)([^\n,]+)'
                priority_match = re.search(priority_pattern, updated_params)
                if priority_match:
                    current_priority_expr = priority_match.group(2).strip()
                    # If it's DEFAULT_PRIORITY based, keep that format
                    if 'DEFAULT_PRIORITY' in current_priority_expr:
                        offset = expected_priority - self.DEFAULT_PRIORITY
                        if offset == 0:
                            new_priority_expr = 'DEFAULT_PRIORITY'
                        elif offset > 0:
                            new_priority_expr = f'DEFAULT_PRIORITY + {offset}'
                        else:
                            new_priority_expr = f'DEFAULT_PRIORITY - {abs(offset)}'
                    else:
                        new_priority_expr = str(expected_priority)

                    updated_params = re.sub(priority_pattern, rf'\g<1>{new_priority_expr}', updated_params)
                    modified = True

            # Update move type if there's a mismatch
            if move_data.move_type:
                type_pattern = r'(MOVE_TYPE:\s*)Type\.\w+'
                if re.search(type_pattern, updated_params):
                    updated_params = re.sub(type_pattern, rf'\g<1>Type.{move_data.move_type}', updated_params)
                    modified = True

            # Update move class if there's a mismatch
            if move_data.move_class:
                class_pattern = r'(MOVE_CLASS:\s*)MoveClass\.\w+'
                if re.search(class_pattern, updated_params):
                    updated_params = re.sub(class_pattern, rf'\g<1>MoveClass.{move_data.move_class}', updated_params)
                    modified = True

            # Replace the params block in the content
            if modified:
                content = content.replace(
                    attack_params_match.group(0),
                    attack_params_match.group(1) + updated_params + attack_params_match.group(3)
                )

        # Handle custom IMoveSet implementations with simple constant returns
        elif result['is_custom_implementation']:
            # Update accuracy constant if there's a mismatch and it's not a complex move
            if move_data.accuracy != '?' and isinstance(move_data.accuracy, int):
                # Try DEFAULT_ACCURACY first
                accuracy_pattern = r'(DEFAULT_ACCURACY\s*=\s*)(\d+)'
                if re.search(accuracy_pattern, content):
                    content = re.sub(accuracy_pattern, rf'\g<1>{move_data.accuracy}', content)
                    modified = True
                else:
                    # Try ACCURACY constant
                    accuracy_pattern = r'(ACCURACY\s*=\s*)(\d+)'
                    if re.search(accuracy_pattern, content):
                        content = re.sub(accuracy_pattern, rf'\g<1>{move_data.accuracy}', content)
                        modified = True

            # Update stamina function if it's a simple constant return
            if (move_data.stamina != '?' and isinstance(move_data.stamina, int) and
                self._is_simple_constant_return(content, 'stamina')):
                stamina_pattern = r'(function\s+stamina\s*\([^)]*\)\s*[^{]*\{\s*return\s+)(\d+)(;)'
                if re.search(stamina_pattern, content, re.DOTALL):
                    content = re.sub(stamina_pattern, rf'\g<1>{move_data.stamina}\g<3>', content, flags=re.DOTALL)
                    modified = True

            # Update priority function if it's a simple constant return
            if (move_data.priority != '?' and isinstance(move_data.priority, int) and
                self._is_simple_constant_return(content, 'priority')):
                expected_priority = self.csv_priority_to_contract_priority(move_data.priority)

                # Calculate the new priority expression
                offset = expected_priority - self.DEFAULT_PRIORITY
                if offset == 0:
                    new_priority_expr = 'DEFAULT_PRIORITY'
                elif offset > 0:
                    new_priority_expr = f'DEFAULT_PRIORITY + {offset}'
                else:
                    new_priority_expr = f'DEFAULT_PRIORITY - {abs(offset)}'

                priority_pattern = r'(function\s+priority\s*\([^)]*\)\s*[^{]*\{\s*return\s+)([^;]+)(;)'
                if re.search(priority_pattern, content, re.DOTALL):
                    content = re.sub(priority_pattern, rf'\g<1>{new_priority_expr}\g<3>', content, flags=re.DOTALL)
                    modified = True

            # Update moveType function if it's a simple constant return
            if move_data.move_type and self._is_simple_constant_return(content, 'moveType'):
                type_pattern = r'(function\s+moveType\s*\([^)]*\)\s*[^{]*\{\s*return\s+)Type\.\w+(;)'
                if re.search(type_pattern, content, re.DOTALL):
                    content = re.sub(type_pattern, rf'\g<1>Type.{move_data.move_type}\g<2>', content, flags=re.DOTALL)
                    modified = True

            # Update moveClass function if it's a simple constant return
            if move_data.move_class and self._is_simple_constant_return(content, 'moveClass'):
                class_pattern = r'(function\s+moveClass\s*\([^)]*\)\s*[^{]*\{\s*return\s+)MoveClass\.\w+(;)'
                if re.search(class_pattern, content, re.DOTALL):
                    content = re.sub(class_pattern, rf'\g<1>MoveClass.{move_data.move_class}\g<2>', content, flags=re.DOTALL)
                    modified = True

        # Write back if modified
        if modified and content != original_content:
            with open(file_path, 'w', encoding='utf-8') as file:
                file.write(content)
            return True

        return False

    def update_all_contracts(self) -> None:
        """Update all contract files with CSV values where there are mismatches"""
        print("\n" + "="*80)
        print("UPDATING CONTRACTS")
        updated_count = 0
        no_changes_count = 0

        for result in self.validation_results:
            if not result['errors']:
                continue

            impl_type = "StandardAttack" if result['is_standard_attack'] else "Custom IMoveSet"
            print(f"\n  Updating ({impl_type}): {result['contract_file']}")

            if self.update_contract_file(result):
                print(f"    ✅ Updated successfully")
                updated_count += 1
            else:
                print(f"    ⚠️  No changes made (may require manual update)")
                no_changes_count += 1
        print(f"Updated {updated_count} files")
        if no_changes_count > 0:
            print(f"{no_changes_count} files had no changes (complex logic may require manual update)")
        print("="*80)


def run(csv_path: str = "drool/moves.csv", src_path: str = "src/") -> bool:
    """
    Run move validation. Returns True if validation passes, False otherwise.

    If validation fails and user accepts changes, re-runs validation until it passes or user declines.
    """
    # Validate paths exist
    if not os.path.exists(csv_path):
        print(f"Error: CSV file not found: {csv_path}")
        return False

    if not os.path.exists(src_path):
        print(f"Error: Source directory not found: {src_path}")
        return False

    # Run validation in a loop - re-run if user accepts changes
    while True:
        validator = MoveValidator(csv_path, src_path)
        validation_passed, changes_made = validator.run_validation()

        if validation_passed:
            print("\n✅ All move validations passed!")
            return True
        elif changes_made:
            # User accepted changes, re-run validation to check if all issues are resolved
            print("\n🔄 Re-running validation after changes...")
            print()
        else:
            # User declined changes
            return False


def main():
    """CLI entry point."""
    import sys

    # Default paths
    csv_path = "drool/moves.csv"
    src_path = "src/"

    # Allow command line arguments
    if len(sys.argv) > 1:
        csv_path = sys.argv[1]
    if len(sys.argv) > 2:
        src_path = sys.argv[2]

    if not run(csv_path, src_path):
        sys.exit(1)


if __name__ == "__main__":
    main()
