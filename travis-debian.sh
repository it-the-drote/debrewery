#!/usr/bin/env bash

source ./debian/package.sh

#travis workaround
#-----------------
export PING_SLEEP=30s
export WORKDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
export BUILD_OUTPUT=$WORKDIR/build.out

touch $BUILD_OUTPUT

dump_output() {
   echo -e "\e[0;31mTailing the last 500 lines of output:\e[0m"
   tail -500 $BUILD_OUTPUT
}

function die() {
    NAME=$1
    DISTRO=$2
    ARCHITECTURE=$3

    dump_output
    test -z $TELEGRAM_TOKEN || curl -XPOST -d "message=Building $NAME on $DISTRO-$ARCHITECTURE failed&token=$TELEGRAM_TOKEN" http://api.it-the-drote.tk/telegram
    exit 1
}

#-----------------


echo -e "\e[0;32mSetting up variables...\e[0m"

DEBREW_SUPPORTED_DISTRIBUTIONS="jessie
wheezy
trusty
xenial"
DEBREW_SUPPORTED_ARCHITECTURES="amd64
i386"

DEBREW_CWD=`pwd`
DEBREW_REPO_OWNER=`echo $DEBREW_CWD | cut -f 5 -d '/'`
DEBREW_SOURCE_NAME=`dpkg-parsechangelog | grep Source | cut -f 2 -d ' '`
DEBREW_REVISION_PREFIX=`dpkg-parsechangelog | grep Version | cut -f 2 -d ' '`
DEBREW_VERSION_PREFIX=`echo $DEBREW_REVISION_PREFIX | cut -f 1 -d '-'`
stable_hash=`git rev-list stable | head -n 1`
current_hash=`git rev-parse HEAD`
changelog_modified=`git show --name-only HEAD | grep -c 'debian/changelog'`

if [[ $stable_hash == $current_hash ]]; then
    if [[ $TRAVIS_BRANCH == 'stable' ]]; then
        if [[ $PRODUCTION_FLAVOURS == 'any' ]]; then
            DEBREW_DISTRIBUTIONS=$DEBREW_SUPPORTED_DISTRIBUTIONS
        else
            DEBREW_DISTRIBUTIONS=$PRODUCTION_FLAVOURS
        fi
        if [[ $PRODUCTION_ARCHITECTURES == 'any' ]]; then
            DEBREW_ARCHITECTURES=$DEBREW_SUPPORTED_ARCHITECTURES
        else
            DEBREW_ARCHITECTURES=$PRODUCTION_ARCHITECTURES
        fi
        DEBREW_ENVIRONMENT='stable'
    else
        echo -e "\e[0;32mThis branch is not "stable", exiting gracefully.\e[0m"
        exit 0
    fi
else
    DEBREW_DISTRIBUTIONS=$TESTING_FLAVOURS
    DEBREW_ARCHITECTURES=$TESTING_ARCHITECTURES
    DEBREW_ENVIRONMENT='testing'
fi

#if [[ $changelog_modified == '0' ]]; then
#    echo -e "\e[0;32mChangelog is not modified, exiting gracefully.\e[0m"
#    exit 0
#fi

for DISTRO in $DEBREW_DISTRIBUTIONS; do
    for ARCH in $DEBREW_ARCHITECTURES; do
        echo -e "\e[0;32mAssembling Dockerfile...\e[0m"
        echo -e "\e[0;32mDistribution: "$DISTRO"-"$ARCH"\e[0m"
        cat >Dockerfile <<EOF
FROM likeall/$DISTRO-$ARCH
WORKDIR $DEBREW_CWD
COPY . .
ENV DEBFULLNAME "Travis CI"
ENV DEBEMAIL repo@crapcannon.tk
ENV LC_ALL en_US.UTF-8
ENV LANG en_US.UTF-8
ENV LANGUAGE en_US.UTF-8
EOF

        test -z $SECRET1 || echo "ENV SECRET1 $SECRET1" >> Dockerfile
        test -z $SECRET2 || echo "ENV SECRET2 $SECRET2" >> Dockerfile
        test -z $SECRET3 || echo "ENV SECRET3 $SECRET3" >> Dockerfile
        cat >> Dockerfile <<EOF
RUN apt-get update
RUN mk-build-deps --install --remove --tool 'apt-get --no-install-recommends --yes' debian/control
RUN dch --preserve --newversion $DEBREW_REVISION_PREFIX"+"$DISTRO ""
RUN dch --preserve -D $DISTRO --force-distribution ""
RUN dh_make --createorig -s -y -p $DEBREW_SOURCE_NAME"_"$DEBREW_VERSION_PREFIX || true
RUN debuild -e SECRET1 -e SECRET2 -e SECRET3 --no-tgz-check -us -uc
CMD /bin/true
EOF
        bash -c "while true; do echo \$(date) - building ...; sleep $PING_SLEEP; done" & PING_LOOP_PID=$!
        echo -e "\e[0;32mBuilding Docker container...\e[0m"
        docker build --tag="debrew/"$DEBREW_SOURCE_NAME"_"$DISTRO . >> $BUILD_OUTPUT 2>&1 || die $DEBREW_SOURCE_NAME $DISTRO $ARCH
        rm -f Dockerfile
        DEBREW_CIDFILE=`mktemp`
        rm -f $DEBREW_CIDFILE
        echo -e "\e[0;32mRunning Docker container...\e[0m"
        docker run --cidfile=$DEBREW_CIDFILE "debrew/"$DEBREW_SOURCE_NAME"_"$DISTRO >> $BUILD_OUTPUT 2>&1 || die $DEBREW_SOURCE_NAME $DISTRO $ARCH
        mkdir ext-build
        echo -e "\e[0;32mExtracting files from Docker container...\e[0m"
        docker cp `cat $DEBREW_CIDFILE`":"$DEBREW_CWD"/../" ./ext-build || die $DEBREW_SOURCE_NAME $DISTRO $ARCH
        cd ./ext-build/$DEBREW_REPO_OWNER/
        echo -e "\e[0;32mPushing build artifacts to the repo...\e[0m"
        for i in `ls *.deb`; do
            if [[ $DEBREW_HIDDEN_REPO == 'true' ]]; then
                DEBREW_FTP_URL="ftp://it-the-drote.tk/hidden/"
            else
                DEBREW_FTP_URL="ftp://it-the-drote.tk/$DEBREW_ENVIRONMENT/$DISTRO/$ARCH/"
            fi
            echo -e "\e[0;31m Uploading $i to $DEBREW_FTP_URL\e[0m"
            curl -s -T "$i" "$DEBREW_FTP_URL" --user travis:$DEBREW_FTP_PASSWORD || die $DEBREW_SOURCE_NAME $DISTRO $ARCH
        done
        cd $DEBREW_CWD
        echo -e "\e[0;32mRemoving Docker container...\e[0m"
        docker rm `cat $DEBREW_CIDFILE`
        rm -f $DEBREW_CIDFILE
        rm -fr ext-build
        kill $PING_LOOP_PID
        rm $BUILD_OUTPUT
    done
done
