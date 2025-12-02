#!/usr/bin/env bash
#
# For licensing see accompanying LICENSE_MODEL file.
# Copyright (C) 2025 Apple Inc. All Rights Reserved.
#
set -e

# Hardcoded parameters
model_size="0.5b"
dest_dir="virtualportal/Models/VLM/FastVLM/model"

# TODO: change to download when folder not exist

# Map model size to full model name
model="llava-fastvithd_0.5b_stage3_llm.fp16"

cleanup() {
    rm -rf "$tmp_dir"
}

download_model() {
    # Download directory
    tmp_dir=$(mktemp -d)

    # Model paths
    base_url="https://ml-site.cdn-apple.com/datasets/fastvlm"

    # Create destination directory if it doesn't exist
    if [ ! -d "$dest_dir" ]; then
        echo "Creating destination directory: $dest_dir"
        mkdir -p "$dest_dir"
    elif [ "$(ls -A "$dest_dir")" ]; then
        echo -e "Destination directory '$dest_dir' exists and is not empty.\n"
        read -p "Do you want to clear it and continue? [y/N]: " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo -e "\nStopping."
            exit 1
        fi
        echo -e "\nClearing existing contents in '$dest_dir'"
        rm -rf "${dest_dir:?}"/*
    fi

    # Temp files
    tmp_zip_file="${tmp_dir}/${model}.zip"
    tmp_extract_dir="${tmp_dir}/${model}"

    mkdir -p "$tmp_extract_dir"

    # Download model
    echo -e "\nDownloading '${model}' model ...\n"
    wget -q --progress=bar:noscroll --show-progress -O "$tmp_zip_file" "$base_url/$model.zip"

    # Unzip model
    echo -e "\nUnzipping model..."
    unzip -q "$tmp_zip_file" -d "$tmp_extract_dir"

    # Copy to destination
    echo -e "\nCopying model files to destination directory..."
    cp -r "$tmp_extract_dir/$model"/* "$dest_dir"

    # Verify
    if [ ! -d "$dest_dir" ] || [ -z "$(ls -A "$dest_dir")" ]; then
        echo -e "\nModel extraction failed. Destination directory '$dest_dir' is missing or empty."
        exit 1
    fi

    echo -e "\nModel downloaded and extracted to '$dest_dir'"
}

# Cleanup on exit
trap cleanup EXIT INT TERM

# Start download
download_model
