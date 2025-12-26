"""Setup for BitBarrel Python client."""

import os
import subprocess
import sys
from pathlib import Path

from setuptools import Extension, setup
from setuptools.command.build_ext import build_ext


# Path to the Nim source
BASE_DIR = Path(__file__).parent.resolve()
NIM_DIR = BASE_DIR / "bitbarrel_core"
NIM_SOURCE = NIM_DIR / "client.nim"


class NimExtension(build_ext):
    """Custom build_ext command to build Nim extensions."""

    def build_extension(self, ext):
        """Build a Nim extension."""
        # Determine output filename
        output_path = self.get_ext_fullpath(ext.name)

        # Ensure output directory exists
        os.makedirs(os.path.dirname(output_path), exist_ok=True)

        # Build the Nim extension
        cmd = [
            "nim",
            "c",
            "--app:lib",
            "--threads:on",
            "--python:on",
            "-d:release",
            f"-o:{output_path}",
            str(NIM_SOURCE),
        ]

        # Add optional nimble path if specified
        nimble_path = os.environ.get("NIMBLE_DIR")
        if nimble_path:
            cmd.append(f"--nimblePath:{nimble_path}")

        print(f"Building Nim extension: {' '.join(cmd)}")

        try:
            result = subprocess.run(
                cmd,
                check=True,
                cwd=BASE_DIR,
                capture_output=True,
                text=True,
            )
            if result.stdout:
                print(result.stdout)
        except subprocess.CalledProcessError as e:
            print(f"Error building Nim extension:", file=sys.stderr)
            print(f"stdout: {e.stdout}", file=sys.stderr)
            print(f"stderr: {e.stderr}", file=sys.stderr)
            sys.exit(1)
        except FileNotFoundError:
            print(
                "Nim compiler not found. Please install Nim from https://nim-lang.org",
                file=sys.stderr,
            )
            sys.exit(1)


# Read version from __init__.py
def get_version():
    """Get version from package."""
    init_file = BASE_DIR / "bitbarrel" / "__init__.py"
    with open(init_file) as f:
        for line in f:
            if line.startswith("__version__"):
                return line.split("=")[1].strip().strip('"').strip("'")
    return "0.1.0"


# Read README for long description
def get_long_description():
    """Get README content for PyPI."""
    readme_file = BASE_DIR / "README.md"
    if readme_file.exists():
        with open(readme_file, encoding="utf-8") as f:
            return f.read()
    return "Python client for BitBarrel key-value storage"


setup(
    name="bitbarrel",
    version=get_version(),
    author="BitBarrel",
    description="Python client for BitBarrel key-value storage",
    long_description=get_long_description(),
    long_description_content_type="text/markdown",
    url="https://github.com/yourusername/bitbarrel",
    license="MIT",
    packages=["bitbarrel"],
    ext_modules=[
        Extension(
            "bitbarrel_core",
            sources=[str(NIM_SOURCE)],
        )
    ],
    cmdclass={"build_ext": NimExtension},
    install_requires=[
        # Runtime dependencies - nimpy is only needed for development
        # The compiled binary is standalone
    ],
    extras_require={
        "dev": ["pytest", "black", "mypy"],
    },
    python_requires=">=3.8",
    classifiers=[
        "Development Status :: 3 - Alpha",
        "Intended Audience :: Developers",
        "License :: OSI Approved :: MIT License",
        "Programming Language :: Python :: 3",
        "Programming Language :: Python :: 3.8",
        "Programming Language :: Python :: 3.9",
        "Programming Language :: Python :: 3.10",
        "Programming Language :: Python :: 3.11",
        "Programming Language :: Python :: 3.12",
        "Programming Language :: Python :: Implementation :: CPython",
    ],
)
