"""Setup for BitBarrel Python client."""

from pathlib import Path
from setuptools import setup, find_packages


# Read version from __init__.py
def get_version():
    """Get version from package."""
    init_file = Path(__file__).parent / "bitbarrel" / "__init__.py"
    with open(init_file) as f:
        for line in f:
            if line.startswith("__version__"):
                return line.split("=")[1].strip().strip('"').strip("'")
    return "0.1.0"


# Read README for long description
def get_long_description():
    """Get README content for PyPI."""
    readme_file = Path(__file__).parent / "README.md"
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
    install_requires=["websocket-client>=1.0.0"],
    extras_require={
        "dev": ["pytest>=7.0", "black>=22.0", "mypy>=0.990"],
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
    ],
)
