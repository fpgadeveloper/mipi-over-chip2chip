# Documentation for the reference design

This folder contains the sources of the documentation of the MIPI over Chip2Chip reference
design. The documentation is a work in progress and has not been published yet. We strongly
encourage you to contribute: you can modify these sources and then make a pull request to
this repository on Github.

## How to build the docs locally

To build the documentation locally, you will need to have Python 3 with Sphinx, MyST parser
and the ReadTheDocs Sphinx theme installed. For this guide, we'll assume that you are using Linux
and that it already has Python 3 installed. Ideally we would create a virtual environment and
install all the packages we need into it using pip:

1. Install `python3-venv` (typically, it's already installed):

```
sudo apt install python3-venv -y
```

2. Create and activate a virtual environment:

```
python3 -m venv sphinx_venv
source sphinx_venv/bin/activate
```

3. In the active virtual environment, install Sphinx, MyST and the ReadTheDocs Sphinx theme:

```
pip install -U sphinx
pip install myst-parser
pip install sphinx-rtd-theme
```

4. Build the docs:

```
cd <path-of-this-repo>/docs
make html
```

To view the locally generated docs, just browse to `<path-of-this-repo>/docs/build/html` and open
the `index.html` in a web browser. Each time you wish to rebuild the docs, you just need to run
`make html` and it will work as long as you have activated the virtual environment first.

The target design tables of the documentation are generated from `config/data.json`.
