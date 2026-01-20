#!/usr/bin/env python3
"""
Master orchestrator script that runs all processing steps in order.

This script:
1. Creates mon spritesheets (96x96 GIFs -> spritesheet)
2. Creates attack spritesheets (attack PNGs -> spritesheet)
3. Validates move contracts against CSV data
4. Generates Solidity deployment script (SetupMons.s.sol)
5. Generates TypeScript data file (mon.ts)

Usage:
    python processing/buildAll.py [options]
    
Options:
    --skip-sprites      Skip spritesheet generation steps (1 & 2)
    --skip-validation   Skip move validation step (3)
    --color             Include sprite/palette color data in Solidity output
"""

import argparse
import os
import sys
from pathlib import Path

# Add processing directory to path for imports
sys.path.insert(0, str(Path(__file__).parent))


def print_step(step_num: int, total: int, description: str):
    """Print a step header."""
    print()
    print("=" * 80)
    print(f"STEP {step_num}/{total}: {description}")
    print("=" * 80)
    print()


def main():
    parser = argparse.ArgumentParser(
        description='Run all processing steps for mon and move data',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__
    )
    parser.add_argument('--skip-sprites', action='store_true',
                       help='Skip spritesheet generation steps')
    parser.add_argument('--skip-validation', action='store_true',
                       help='Skip move validation step')
    parser.add_argument('--color', action='store_true',
                       help='Include sprite/palette color data in Solidity output')
    args = parser.parse_args()

    # Change to repository root
    repo_root = Path(__file__).parent.parent
    os.chdir(repo_root)
    print(f"Working directory: {repo_root}")

    total_steps = 5
    if args.skip_sprites:
        total_steps -= 2
    if args.skip_validation:
        total_steps -= 1

    current_step = 0
    
    # Step 1: Create mon spritesheets
    if not args.skip_sprites:
        current_step += 1
        print_step(current_step, total_steps, "Creating mon spritesheets")
        
        from createMonSpritesheets import run as run_mon_sprites
        if not run_mon_sprites():
            print("\n❌ Failed to create mon spritesheets")
            sys.exit(1)

    # Step 2: Create attack spritesheets
    if not args.skip_sprites:
        current_step += 1
        print_step(current_step, total_steps, "Creating attack spritesheets")
        
        from createAttackSpritesheets import run as run_attack_sprites
        if not run_attack_sprites():
            print("\n❌ Failed to create attack spritesheets")
            sys.exit(1)

    # Step 3: Validate moves
    if not args.skip_validation:
        current_step += 1
        print_step(current_step, total_steps, "Validating move contracts")
        
        from validateMoves import run as run_validate
        if not run_validate():
            print("\n⚠️  Move validation found issues. Please review and run again.")
            sys.exit(1)

    # Step 4: Generate Solidity
    current_step += 1
    print_step(current_step, total_steps, "Generating Solidity deployment script")
    
    from generateSolidity import run as run_solidity
    if not run_solidity(include_color=args.color):
        print("\n❌ Failed to generate Solidity deployment script")
        sys.exit(1)

    # Step 5: Generate TypeScript
    current_step += 1
    print_step(current_step, total_steps, "Generating TypeScript data file")
    
    from processing.generateMonsTypeScript import run as run_typescript
    if not run_typescript():
        print("\n❌ Failed to generate TypeScript data file")
        sys.exit(1)

    # Success!
    print()
    print("=" * 80)
    print("✅ All processing steps completed successfully!")
    print("=" * 80)
    print()
    print("Generated files:")
    print("  - drool/imgs/mon_spritesheet.png (if sprites were processed)")
    print("  - drool/imgs/attacks/attack_spritesheet.png (if sprites were processed)")
    print("  - script/SetupMons.s.sol")
    print("  - munch/src/app/data/mon.ts")


if __name__ == "__main__":
    main()

