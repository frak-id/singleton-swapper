#!/bin/bash

git submodule deinit --force .
git submodule update --init --recursive
