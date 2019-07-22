#!/bin/bash
if [[ $* == *--daemon* ]]; then
	./mediabot.pl $*
else
	echo "This script is for internal use. Do not use it."
fi