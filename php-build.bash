#!/bin/bash
set -e

php_build_version="build2.2.1"

# Check for required variables:
if [ "$#" -lt 1 ]; then
    echo "Must pass argument 1: the name of the action currently running"
    exit 1
fi
echo "Running php-build $1" >> output.log 2>&1

if [ -z "$GITHUB_ACTOR" ]
then
	echo "Error: GITHUB_ACTOR variable not set"
	exit 1
fi

if [ -z "$GITHUB_REPOSITORY" ]
then
	echo "Error: GITHUB_REPOSITORY variable not set"
	exit 1
fi

if [ -z "$ACTION_TOKEN" ]
then
	echo "Error: ACTION_TOKEN variable not set"
	exit 1
fi

if [ -z "$ACTION_PHP_VERSION" ]
then
	echo "Error: ACTION_PHP_VERSION variable not set"
	exit 1
fi

if [ -z "$PHP_CACHE_ARCH" ]
then
	echo "Error: PHP_CACHE_ARCH variable not set"
	exit 1
fi

# The dockerfile is created in-memory and written to disk at the end of this script.
# Below, depending on the Action's inputs, more lines may be written to this dockerfile.
# Zip and git are required for Composer to work correctly.
base_image="php:"
if [ "$ACTION_PHP_VERSION" != "latest" ]
then
	base_image="${base_image}${ACTION_PHP_VERSION}-"
fi
base_image="${base_image}cli-alpine"
dockerfile="FROM ${base_image}
RUN apk add --update --no-cache bash coreutils git make openssh patch unzip zip
# INI settings to set within Github Action's build runner
RUN echo 'memory_limit=4G' > /usr/local/etc/php/conf.d/php-build.ini"

base_repo="$1"

# We log into the Github docker repository on behalf of the user that is
# running the action (this could be anyone, outside of the php-actions organisation).
echo "${ACTION_TOKEN}" | docker login docker.pkg.github.com -u "${GITHUB_ACTOR}" --password-stdin >> output.log 2>&1

# If there are any extensions to be installed, we do this using the
# install-php-extensions tool. If there are not extensions required, we don't
# need to install this tool at all.
if [ -n "$ACTION_PHP_EXTENSIONS" ]
then
	dockerfile="${dockerfile}
ADD https://github.com/mlocati/docker-php-extension-installer/releases/latest/download/install-php-extensions /usr/local/bin/"
	dockerfile="${dockerfile}
RUN chmod +x /usr/local/bin/install-php-extensions && sync && install-php-extensions"
fi

# For each extension installed, we add the name to the end of the
# dockerfile_unique variable, which is used to tag the Docker image.
dockerfile_unique="php-${ACTION_PHP_VERSION}"
for ext in $ACTION_PHP_EXTENSIONS
do
	dockerfile="${dockerfile} $ext"
	dockerfile_unique="${dockerfile_unique}-${ext}"
done
dockerfile_unique="${dockerfile_unique}-${php_build_version}-${PHP_CACHE_ARCH}"

# Remove illegal characters and make lowercase:
GITHUB_REPOSITORY="${GITHUB_REPOSITORY,,}"
dockerfile_unique="${dockerfile_unique// /_}"
dockerfile_unique="${dockerfile_unique,,}"
repo_without_org=$(echo "$GITHUB_REPOSITORY" | sed "s/[^\/]*\///")

# This tag will be used to identify the built dockerfile. Once it is built,
# it should not need to be built again unless there is a PHP update, so after
# the first Github Actions run the build should be very quick.
# Note: The GITHUB_REPOSITORY is the repo where the action is running, nothing
# to do with the php-actions organisation. This means that the image is pushed
# onto a user's Github profile (currently not shared between other users).
docker_tag="docker.pkg.github.com/${GITHUB_REPOSITORY}/php-actions_${base_repo}_${repo_without_org}:${dockerfile_unique}"
echo "$docker_tag" > ./docker_tag

# Attempt to pull the existing Docker image, if it exists. If the image has
# been pushed previously, this image should take preference and a new image
# will not need to be built.
echo "Pulling $docker_tag" >> output.log 2>&1

# No need to continue building the image if the pull was successful.
if docker pull "$docker_tag" >> output.log 2>&1; then
	# Unless the PHP version has an update...

	# Pull latest PHP Docker image so we can check its version.
	echo "Pulling $base_image" >> output.log 2>&1
	if docker pull "$base_image" >> output.log 2>&1; then
		# Check PHP versions of the latest PHP tag and our tag.
		base_image_php_version=$(docker run -i "$base_image" php -r "echo PHP_VERSION;")
		cached_image_php_version=$(docker run -i "$docker_tag" php -r "echo PHP_VERSION;")

		echo "Comparing $cached_image_php_version (cached) to $base_image_php_version (latest)." >> output.log 2>&1

		# No need to continue building if our image already exists and PHP is up-to-date.
		if [ $cached_image_php_version == $base_image_php_version ]; then
			exit
		fi
	else
		echo "Pulling from upstream failed, ignoring update check" >> output.log 2>&1
		exit
	fi
fi

echo "Building PHP $ACTION_PHP_VERSION with extensions: $ACTION_PHP_EXTENSIONS ..."
# Save the dockerfile to a physical file on disk, then build the image, tagging
# it with the unique tag. If the layers are already built, there should be no
# need to re-build, and the `docker build` step should use the cached layers of
# what has just been pulled.
echo "$dockerfile" > Dockerfile-php-build
if [ ACTIONS_RUNNER_DEBUG = "true" ]
then
	echo "Dockerfile:"
	echo "$dockerfile"
	echo docker build --tag "$docker_tag" --cache-from "$docker_tag" --file Dockerfile-php-build .

fi

docker build --tag "$docker_tag" --cache-from "$docker_tag" --file Dockerfile-php-build . >> output.log 2>&1

# Update the user's repository with the customised docker image, ready for the
# next Github Actions run.
if ! docker push "$docker_tag" >> output.log 2>&1; then
	echo "WARNING: Failed to push Docker image to \"$docker_tag\", this is probably due to missing permissions on GitHub." >> output.log 2>&1
	echo "Will continue as this is just an optimization to improve speed of next build." >> output.log 2>&1
fi
