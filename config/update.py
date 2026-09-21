'''
Opsero Electronic Design Inc.

data.json is intended to be a centralized source of information regarding all of the target
designs and it ensures that the documentation and build scripts are consistent.
When data.json is updated with new information, this Python script can be run to update
the main README.md file of the repo, the Vivado build script and the .gitignore. We typically
use this script when adding/removing target designs.

The Sphinx documentation also refers to the data.json file when compiling the target design
and supported board tables.

This repo differs from most Opsero reference designs in that its targets are not alternative
variants: they are the two halves of ONE two-board system (see the "role" field):
  * role "host"      - the board with the processor that runs Linux and controls the system
  * role "mezzanine" - the processor-less FPGA board that carries the cameras

The script can be run from any directory (paths are resolved relative to this file):
    python3 config/update.py
'''

import os
import json

# All paths are relative to this file so that the script works from any directory
CONFIG_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(CONFIG_DIR)

def repo_path(*parts):
    return os.path.join(REPO_DIR, *parts)

# Load the JSON data
def load_json(filename):
    with open(filename) as f:
        return json.load(f)

# Create the design table for the README.md file
# This function determines the formatting of the design table. Both targets belong to the
# same system, so they are listed in a single table (in data.json order) rather than in
# one table per device group.
def create_tables(data):
    # Emoji dict
    to_emoji = {True: ":white_check_mark:", False: ":x:"}
    # License dict
    to_edition = {True: "Enterprise", False: "Standard :free:"}
    # IP license dict (separately-licensed IP cores, e.g. TEMAC/XXV/HDMI/MRMAC)
    to_ip = {True: "Required", False: "-"}
    # Group label -> display name
    group_names = {group['label']: group['name'] for group in data['groups']}
    tables = []
    links = {}
    tables.append('| Target board          | Target design   | Role      | Device           | Connector | Cameras | Baremetal<br> App | PetaLinux<br> Build | Yocto<br> Build | Vivado<br> Edition | IP<br>License |')
    tables.append('|-----------------------|-----------------|-----------|------------------|-----------|---------|-------|-------|-------|-------|-------|')
    for design in data['designs']:
        if not design['publish']:
            continue
        cols = []
        cols.append('[{0}]'.format(design['board']).ljust(21))
        cols.append('`{0}`'.format(design['label']).ljust(15))
        cols.append('{0}'.format(design['role']).ljust(9))
        cols.append('{0}'.format(group_names[design['group']]).ljust(16))
        cols.append('{0}'.format(design['connector']).ljust(9))
        cols.append('{0}'.format(len(design['cams'])).ljust(7))
        cols.append('{0}'.format(to_emoji[design['baremetal']]).ljust(18))
        cols.append('{0}'.format(to_emoji[design['petalinux']]).ljust(18))
        cols.append('{0}'.format(to_emoji[design.get('yocto', False)]).ljust(18))
        cols.append('{0}'.format(to_edition[design['license']]).ljust(5))
        cols.append('{0}'.format(to_ip[design.get('ip_license', False)]).ljust(5))
        tables.append('| ' + ' | '.join(cols) + ' |')
        links[design['board']] = design['link']
    tables.append('')
    # Add the board links
    for k,v in links.items():
        tables.append('[{0}]: {1}'.format(k,v))
    return(tables)

# Update the README.md file target design tables
def update_readme(file_path,data):
    # Create the tables from the data
    tables = create_tables(data)
    # Read the content of the file
    with open(file_path, 'r') as infile:
        lines = infile.readlines()

    # Open the same file in write mode to overwrite it
    with open(file_path, 'w') as outfile:
        inside_updater = False

        for line in lines:
            if '<!-- updater start -->' in line:
                # Write the start tag to the file
                outfile.write(line)
                # Write the tables
                for l in tables:
                    outfile.write("{}\n".format(l))
                inside_updater = True
            elif '<!-- updater end -->' in line:
                # Write the end tag to the file
                outfile.write(line)
                inside_updater = False
            elif not inside_updater:
                # Write the line if not inside the updater block
                outfile.write(line)

# Target table of Vivado/scripts/build.tcl. One line per target:
#   dict set target_dict <label> { <board_url> <board_name> { <cams> } <bd_script> <role> }
# The block design script is Vivado/src/bd/bd_<bd_script>.tcl. The 'fpga' group maps to
# bd_fpga.tcl because the FPGA target of this design has no processor (no MicroBlaze).
def get_vivado_build_targets(data):
    templates = {'fpga': 'fpga', 'z7': 'zynq', 'zu': 'zynqmp', 'versal': 'versal'}
    targets = []
    for design in data['designs']:
        template = templates[design['group']]
        cams = '{'
        for cam in design['cams']:
            cams += ' ' + str(cam)
        cams += ' }'
        target = 'dict set target_dict {} {{ {} {} {} {} {} }}'.format(design['label'],design['url'],design['boardname'],
            cams,template,design['role'])
        targets.append(target)
    return(targets)

# Per-target Vivado project directories (the per-target Yocto workspaces are covered by
# Yocto/.gitignore and the Vitis workspaces by static lines of the top-level .gitignore;
# this repo has no PetaLinux flow)
def get_ignore_paths(data):
    paths = []
    for design in data['designs']:
        p = 'Vivado/{}/'.format(design['label'])
        paths.append(p)
    return(paths)

# Update a file that uses "# UPDATER START" and "# UPDATER END" tags
def update_file(file_path,targets):
    # Read the content of the file
    with open(file_path, 'r') as infile:
        lines = infile.readlines()

    # Open the same file in write mode to overwrite it
    with open(file_path, 'w') as outfile:
        inside_updater = False

        for line in lines:
            if '# UPDATER START' in line:
                # Write the start tag to the file
                outfile.write(line)
                # Write the targets
                for l in targets:
                    outfile.write("{}\n".format(l))
                inside_updater = True
            elif '# UPDATER END' in line:
                # Write the end tag to the file
                outfile.write(line)
                inside_updater = False
            elif not inside_updater:
                # Write the line if not inside the updater block
                outfile.write(line)

# Make sure that every target design has a constraints file and a block design script
def check_sources(data):
    templates = {'fpga': 'fpga', 'z7': 'zynq', 'zu': 'zynqmp', 'versal': 'versal'}
    for design in data['designs']:
        filename = repo_path('Vivado','src','constraints','{}.xdc'.format(design['label']))
        if not os.path.isfile(filename):
            print('WARNING: No constraints file found for target',design['label'])
        filename = repo_path('Vivado','src','bd','bd_{}.tcl'.format(templates[design['group']]))
        if not os.path.isfile(filename):
            print('WARNING: No block design script found for target',design['label'],
                '(expected {})'.format(os.path.relpath(filename,REPO_DIR)))

# Make sure that every design has a role and that the system has exactly one host
def check_roles(data):
    roles = [design.get('role') for design in data['designs']]
    for design in data['designs']:
        if design.get('role') not in ('host','mezzanine'):
            print('WARNING: Target',design['label'],'has no valid "role" (host|mezzanine)')
    if roles.count('host') != 1:
        print('WARNING: Expected exactly one target with role "host", found',roles.count('host'))

if __name__ == '__main__':
    # Read the JSON data
    data = load_json(repo_path('config','data.json'))

    # Update the main README.md file
    update_readme(repo_path('README.md'),data)

    # NOTE: build.py reads the targets from data.json at runtime, so there is no
    # generated target list to maintain for the build runner.
    # Update the Vivado build.tcl
    vivado_build_targets = get_vivado_build_targets(data)
    update_file(repo_path('Vivado','scripts','build.tcl'),vivado_build_targets)

    # Update the gitignore
    gitignore_paths = get_ignore_paths(data)
    update_file(repo_path('.gitignore'),gitignore_paths)

    # Checks
    check_roles(data)
    check_sources(data)
