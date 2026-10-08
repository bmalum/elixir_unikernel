#!/usr/bin/env python3
"""Publish a raw disk image as an EC2 AMI.

    scripts/ami-publish.py build/disk-linux.raw --name elixir_unikernel-0.1.0-linux \
        --version 0.1.0 --kernel linux [--force]

Uses the EBS direct APIs (StartSnapshot / PutSnapshotBlock / CompleteSnapshot)
instead of VM Import: no S3 bucket, no `vmimport` IAM role, and all-zero
512 KiB blocks are skipped, so a 1 GiB image with 15 MB of content uploads in
seconds. The snapshot is then registered as a UEFI, ENA-enabled, x86-64 HVM
AMI with the root device /dev/xvda.

Idempotent: an AMI with the same name is reused and printed; `--force`
deregisters it (and deletes its snapshot) first. Everything is tagged
Project=elixir_unikernel Version=<version> Kernel=<kernel>.

Region and credentials come from the environment (AWS_PROFILE, AWS_REGION).
Prints the AMI id on stdout; progress goes to stderr.
"""

import argparse
import base64
import hashlib
import os
import sys
import time

import boto3

BLOCK = 512 * 1024
GIB = 1024 ** 3


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def find_image(ec2, name):
    r = ec2.describe_images(Owners=["self"], Filters=[{"Name": "name", "Values": [name]}])
    imgs = r["Images"]
    return imgs[0] if imgs else None


def deregister(ec2, image):
    log(f"deregistering {image['ImageId']} ({image['Name']})")
    ec2.deregister_image(ImageId=image["ImageId"])
    for bdm in image.get("BlockDeviceMappings", []):
        snap = bdm.get("Ebs", {}).get("SnapshotId")
        if snap:
            for _ in range(30):
                try:
                    ec2.delete_snapshot(SnapshotId=snap)
                    log(f"deleted {snap}")
                    break
                except ec2.exceptions.ClientError as e:
                    if "InvalidSnapshot.InUse" in str(e):
                        time.sleep(2)
                        continue
                    raise


def upload_snapshot(ebs, ec2, path, description, tags):
    size = os.path.getsize(path)
    vol_gib = max(1, -(-size // GIB))
    r = ebs.start_snapshot(
        VolumeSize=vol_gib,
        Description=description,
        Tags=tags,
        Timeout=60,
    )
    snap = r["SnapshotId"]
    log(f"snapshot {snap}: {vol_gib} GiB volume, uploading non-zero {BLOCK // 1024} KiB blocks")
    zero = bytes(BLOCK)
    written = 0
    with open(path, "rb") as f:
        idx = 0
        while True:
            data = f.read(BLOCK)
            if not data:
                break
            if len(data) < BLOCK:
                data = data + bytes(BLOCK - len(data))
            if data != zero:
                digest = base64.b64encode(hashlib.sha256(data).digest()).decode()
                ebs.put_snapshot_block(
                    SnapshotId=snap,
                    BlockIndex=idx,
                    BlockData=data,
                    DataLength=BLOCK,
                    Checksum=digest,
                    ChecksumAlgorithm="SHA256",
                )
                written += 1
            idx += 1
    ebs.complete_snapshot(SnapshotId=snap, ChangedBlocksCount=written)
    log(f"uploaded {written} blocks ({written * BLOCK // (1024 * 1024)} MB); waiting for completion")
    ec2.get_waiter("snapshot_completed").wait(SnapshotIds=[snap], WaiterConfig={"Delay": 5, "MaxAttempts": 120})
    return snap


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("--name", required=True)
    ap.add_argument("--version", required=True)
    ap.add_argument("--kernel", required=True, choices=["linux", "asterinas"])
    ap.add_argument("--force", action="store_true", help="replace an existing AMI of the same name")
    a = ap.parse_args()

    ec2 = boto3.client("ec2")
    ebs = boto3.client("ebs")
    tags = [
        {"Key": "Project", "Value": "elixir_unikernel"},
        {"Key": "Version", "Value": a.version},
        {"Key": "Kernel", "Value": a.kernel},
        {"Key": "Name", "Value": a.name},
    ]

    existing = find_image(ec2, a.name)
    if existing and not a.force:
        log(f"reusing {existing['ImageId']} ({a.name}); pass --force to replace")
        print(existing["ImageId"])
        return
    if existing:
        deregister(ec2, existing)

    snap = upload_snapshot(ebs, ec2, a.image, f"{a.name} root", tags)
    r = ec2.register_image(
        Name=a.name,
        Description=f"elixir_unikernel {a.version} ({a.kernel} kernel): Erlang VM as the init process",
        Architecture="x86_64",
        RootDeviceName="/dev/xvda",
        BlockDeviceMappings=[
            {
                "DeviceName": "/dev/xvda",
                "Ebs": {"SnapshotId": snap, "VolumeType": "gp3", "DeleteOnTermination": True},
            }
        ],
        VirtualizationType="hvm",
        EnaSupport=True,
        SriovNetSupport="simple",
        BootMode="uefi",
        TagSpecifications=[{"ResourceType": "image", "Tags": tags}],
    )
    ami = r["ImageId"]
    ec2.get_waiter("image_available").wait(ImageIds=[ami], WaiterConfig={"Delay": 5, "MaxAttempts": 60})
    log(f"registered {ami} ({a.name})")
    print(ami)


if __name__ == "__main__":
    main()
