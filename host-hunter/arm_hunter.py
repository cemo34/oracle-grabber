#!/usr/bin/env python3
import json
import logging
import os
import subprocess
import sys
from datetime import datetime, timezone
from typing import List, Optional

import oci
from oci.exceptions import ServiceError


ACTIVE_STATES = {"PROVISIONING", "STARTING", "RUNNING", "STOPPING", "STOPPED"}
RETRYABLE_TOKENS = (
    "outofhostcapacity",
    "out of host capacity",
    "out of capacity",
    "limitexceeded",
    "toomanyrequests",
    "requestexception",
    "timed out",
    "timeout",
    "internalerror",
)


def env(name: str, default: str = "") -> str:
    return os.getenv(name, default).strip()


def setup_logging() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%SZ",
    )
    logging.Formatter.converter = lambda *args: datetime.now(timezone.utc).timetuple()


def read_ssh_key() -> Optional[str]:
    key_inline = env("SSH_PUBLIC_KEY")
    if key_inline:
        return key_inline.replace("\\n", "\n").replace("\r", "").replace("\n", "").strip()

    key_file = env("SSH_PUBLIC_KEY_FILE", "/opt/arm-hunter/id_rsa.pub")
    if os.path.isfile(key_file):
        with open(key_file, "r", encoding="utf-8") as f:
            return f.read().replace("\r", "").replace("\n", "").strip()
    return None


def is_retryable(err: Exception) -> bool:
    text = str(err).lower()
    return any(token in text for token in RETRYABLE_TOKENS)


def pick_subnet(vcn_client: oci.core.VirtualNetworkClient, compartment_id: str) -> str:
    subnet_id = env("SUBNET_ID")
    if subnet_id:
        return subnet_id

    response = vcn_client.list_subnets(compartment_id=compartment_id)
    candidates = [
        s.id
        for s in response.data
        if s.lifecycle_state == "AVAILABLE" and not bool(s.prohibit_public_ip_on_vnic)
    ]
    if not candidates:
        raise RuntimeError("No suitable public subnet found; set SUBNET_ID explicitly")
    return candidates[0]


def get_availability_domains(identity_client: oci.identity.IdentityClient, tenancy_id: str) -> List[str]:
    response = identity_client.list_availability_domains(compartment_id=tenancy_id)
    ads = [ad.name for ad in response.data if ad.name]
    if not ads:
        raise RuntimeError("Could not fetch availability domains")
    return ads


def find_arm_image(compute_client: oci.core.ComputeClient, tenancy_id: str, shape: str) -> str:
    images = compute_client.list_images(
        compartment_id=tenancy_id,
        shape=shape,
        operating_system="Canonical Ubuntu",
        operating_system_version="24.04",
    ).data

    if not images:
        all_images = compute_client.list_images(compartment_id=tenancy_id, shape=shape).data
        images = [
            img
            for img in all_images
            if img.lifecycle_state == "AVAILABLE"
            and "ubuntu" in (img.display_name or "").lower()
            and "24.04" in (img.display_name or "")
        ]

    if not images:
        raise RuntimeError("No Ubuntu 24 image found for ARM shape")

    images.sort(key=lambda i: i.time_created, reverse=True)
    return images[0].id


def existing_instance_count(compute_client: oci.core.ComputeClient, compartment_id: str, display_name: str) -> int:
    instances = compute_client.list_instances(compartment_id=compartment_id).data
    return sum(
        1
        for inst in instances
        if inst.display_name == display_name and str(inst.lifecycle_state) in ACTIVE_STATES
    )


def launch_once_per_ad(
    compute_client: oci.core.ComputeClient,
    ads: List[str],
    compartment_id: str,
    subnet_id: str,
    image_id: str,
    display_name: str,
    shape: str,
    ocpus: int,
    memory_gbs: int,
    ssh_public_key: Optional[str],
) -> bool:
    metadata = {}
    if ssh_public_key and ssh_public_key.startswith(("ssh-rsa ", "ssh-ed25519 ", "ecdsa-sha2-nistp256 ")):
        metadata = {"ssh_authorized_keys": ssh_public_key}

    for ad in ads:
        logging.info("Trying ARM in AD: %s", ad)
        try:
            details = oci.core.models.LaunchInstanceDetails(
                availability_domain=ad,
                compartment_id=compartment_id,
                display_name=display_name,
                shape=shape,
                shape_config=oci.core.models.LaunchInstanceShapeConfigDetails(
                    ocpus=ocpus,
                    memory_in_gbs=memory_gbs,
                ),
                source_details=oci.core.models.InstanceSourceViaImageDetails(
                    source_type="image",
                    image_id=image_id,
                ),
                create_vnic_details=oci.core.models.CreateVnicDetails(
                    subnet_id=subnet_id,
                    assign_public_ip=True,
                ),
                metadata=metadata,
            )

            response = compute_client.launch_instance(details)
            logging.info("Launch SUCCESS in %s. Instance ID: %s", ad, response.data.id)
            return True
        except ServiceError as e:
            logging.warning("Launch failed in %s: %s", ad, e)
            if is_retryable(e):
                continue
            raise

    return False


def run_cleanup_if_needed() -> None:
    cleanup_on_success = env("CLEANUP_ON_SUCCESS", "true").lower() in {"1", "true", "yes"}
    if not cleanup_on_success:
        return

    cmd = env("SUCCESS_CLEANUP_CMD", "/opt/arm-hunter/cleanup_hunter.sh --success")
    logging.info("Running cleanup command: %s", cmd)
    subprocess.run(cmd, shell=True, check=False)


def main() -> int:
    setup_logging()

    config_file = env("OCI_CONFIG_FILE", "/opt/arm-hunter/config")
    profile = env("OCI_PROFILE", "DEFAULT")

    config = oci.config.from_file(file_location=config_file, profile_name=profile)
    region_override = env("OCI_REGION")
    if region_override:
        config["region"] = region_override

    identity_client = oci.identity.IdentityClient(config)
    compute_client = oci.core.ComputeClient(config)
    vcn_client = oci.core.VirtualNetworkClient(config)

    tenancy_id = config["tenancy"]
    compartment_id = env("COMPARTMENT_ID", tenancy_id)
    shape = env("SHAPE", "VM.Standard.A1.Flex")
    display_name = env("DISPLAY_NAME", "Binance-Bot-ARM-Ubuntu24")
    ocpus = int(env("OCPUS", "4"))
    memory_gbs = int(env("MEMORY_GBS", "24"))

    ssh_public_key = read_ssh_key()

    try:
        subnet_id = pick_subnet(vcn_client, compartment_id)
        ad_list = get_availability_domains(identity_client, tenancy_id)
        image_id = find_arm_image(compute_client, tenancy_id, shape)

        count = existing_instance_count(compute_client, compartment_id, display_name)
        if count > 0:
            logging.info("Existing ARM instance already found (%s).", count)
            run_cleanup_if_needed()
            return 0

        launched = launch_once_per_ad(
            compute_client=compute_client,
            ads=ad_list,
            compartment_id=compartment_id,
            subnet_id=subnet_id,
            image_id=image_id,
            display_name=display_name,
            shape=shape,
            ocpus=ocpus,
            memory_gbs=memory_gbs,
            ssh_public_key=ssh_public_key,
        )

        if launched:
            run_cleanup_if_needed()
            return 0

        logging.info("No capacity right now; will retry in next timer cycle.")
        return 0
    except Exception as e:
        if is_retryable(e):
            logging.warning("Retryable error: %s", e)
            return 0
        logging.exception("Fatal error")
        return 1


if __name__ == "__main__":
    sys.exit(main())
