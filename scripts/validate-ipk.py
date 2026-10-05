"""Validate and export an IPK: validate-ipk.py PACKAGE_DIR OUTPUT_DIR."""

import io
from pathlib import Path
import re
import shutil
import sys
import tarfile

if len(sys.argv) != 3:
    raise SystemExit("Usage: validate-ipk.py PACKAGE_DIR OUTPUT_DIR")

packages = list(Path(sys.argv[1]).rglob("luci-app-vpn-nftset_*_all.ipk"))
if len(packages) != 1:
    raise SystemExit(
        "Expected one built luci-app-vpn-nftset IPK, found %d." % len(packages)
    )
package = packages[0]
with tarfile.open(package, "r:gz") as archive:
    members = {
        member.name[2:] if member.name.startswith("./") else member.name: member
        for member in archive
    }
    if archive.extractfile(members["debian-binary"]).read().strip() != b"2.0":
        raise SystemExit("Invalid IPK format version.")
    with tarfile.open(
        fileobj=io.BytesIO(archive.extractfile(members["control.tar.gz"]).read()),
        mode="r:gz",
    ) as control_archive:
        control_members = {
            member.name[2:] if member.name.startswith("./") else member.name: member
            for member in control_archive
        }
        control = (
            control_archive.extractfile(control_members["control"]).read().decode()
        )
        fields = dict(
            line.split(": ", 1) for line in control.splitlines() if ": " in line
        )
        if (
            fields.get("Package") != "luci-app-vpn-nftset"
            or fields.get("Architecture") != "all"
        ):
            raise SystemExit("Unexpected package identity or architecture.")
        if (
            not fields.get("Version")
            or package.name != "luci-app-vpn-nftset_%s_all.ipk" % fields["Version"]
        ):
            raise SystemExit("The IPK filename must match its declared version.")
        if "luci-compat" not in re.split(r"[\s,()]+", fields.get("Depends", "")):
            raise SystemExit("The IPK must declare its luci-compat dependency.")
        conffiles = (
            control_archive.extractfile(control_members["conffiles"])
            .read()
            .decode()
            .splitlines()
        )
        if "/etc/config/vpn-nftset" not in conffiles:
            raise SystemExit(
                "The IPK must preserve the user configuration on upgrades."
            )
    with tarfile.open(
        fileobj=io.BytesIO(archive.extractfile(members["data.tar.gz"]).read()),
        mode="r:gz",
    ) as data_archive:
        data_members = {
            member.name[2:] if member.name.startswith("./") else member.name: member
            for member in data_archive
        }
        for path in (
            "etc/config/vpn-nftset",
            "usr/lib/lua/vpn_nftset.lua",
            "usr/lib/lua/luci/controller/vpn-nftset.lua",
            "usr/lib/lua/luci/model/cbi/vpn-nftset.lua",
            "usr/lib/lua/luci/i18n/vpn-nftset.zh-cn.lmo",
            "www/luci-static/resources/vpn-nftset.js",
            "www/luci-static/resources/vpn-nftset.css",
            "usr/share/vpn-nftset/telegram-cidr.txt",
            "usr/share/rpcd/acl.d/luci-app-vpn-nftset.json",
            "lib/upgrade/keep.d/vpn-nftset",
        ):
            member = data_members.get(path)
            if member is None or not member.isfile() or member.size == 0:
                raise SystemExit("Missing package resource: " + path)
        if not any(
            path.startswith("usr/lib/lua/luci/view/vpn-nftset/")
            and path.endswith(".htm")
            for path in data_members
        ):
            raise SystemExit("The IPK must include its LuCI views.")
        for path in (
            "etc/init.d/vpn-nftset",
            "etc/hotplug.d/iface/99-vpn-nftset",
            "etc/uci-defaults/luci-vpn-nftset",
            "usr/bin/vpn-nftset-rulegenerator",
            "usr/bin/vpn-nftset-data",
            "usr/bin/vpn-nftset-update",
        ):
            member = data_members.get(path)
            if (
                member is None
                or not member.isfile()
                or member.size == 0
                or not member.mode & 0o111
            ):
                raise SystemExit("Missing executable package resource: " + path)

destination = Path(sys.argv[2]) / package.name
temporary = destination.with_suffix(".ipk.tmp")
shutil.copyfile(package, temporary)
temporary.replace(destination)
print("Validated and exported " + str(destination))
