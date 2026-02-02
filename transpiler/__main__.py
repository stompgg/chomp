"""Allow running the transpiler as a module: python -m transpiler"""
from .sol2ts import main

if __name__ == '__main__':
    main()
