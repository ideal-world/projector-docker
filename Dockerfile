FROM debian AS ideDownloader

# prepare tools:
RUN apt-get update
RUN apt-get install wget -y
# download IDE to the /ide dir:
WORKDIR /download
ARG downloadUrl
RUN wget -q $downloadUrl -O - | tar -xz
RUN find . -maxdepth 1 -type d -name * -execdir mv {} /ide \;

FROM amazoncorretto:11 as projectorGradleBuilder

# copy projector-core and awt:
ENV PROJECTOR_DIR /projector
ADD projector-awt $PROJECTOR_DIR/projector-awt
ADD projector-core $PROJECTOR_DIR/projector-core
# build projector-core:
WORKDIR $PROJECTOR_DIR/projector-core
ARG buildGradle
RUN if [ "$buildGradle" = "true" ]; then ./gradlew clean; else echo "Skipping gradle build"; fi
RUN if [ "$buildGradle" = "true" ]; then ./gradlew :projector-client-web:browserProductionWebpack; else echo "Skipping gradle build"; fi
RUN rm projector-client-web/build/distributions/projector-client-web.js.map
RUN if [ "$buildGradle" = "true" ]; then ./gradlew :projector-server:distZip; else echo "Skipping gradle build"; fi
RUN if [ "$buildGradle" = "true" ]; then ./gradlew :projector-plugin-markdown:buildPlugin; else echo "Skipping gradle build"; fi

FROM debian AS projectorStaticFiles

# prepare tools:
RUN apt-get update
RUN apt-get install unzip -y
# create the Projector dir:
ENV PROJECTOR_DIR /projector
RUN mkdir -p $PROJECTOR_DIR
# copy IDE:
COPY --from=ideDownloader /ide $PROJECTOR_DIR/ide
# copy projector files to the container:
ADD projector-docker/static $PROJECTOR_DIR
# copy projector:
COPY --from=projectorGradleBuilder $PROJECTOR_DIR/projector-core/projector-client-web/build/distributions $PROJECTOR_DIR/distributions
COPY --from=projectorGradleBuilder $PROJECTOR_DIR/projector-core/projector-server/build/distributions/projector-server-1.0-SNAPSHOT.zip $PROJECTOR_DIR
COPY --from=projectorGradleBuilder $PROJECTOR_DIR/projector-core/projector-plugin-markdown/build/distributions/projector-plugin-markdown-1.0-SNAPSHOT.zip $PROJECTOR_DIR
# prepare IDE - apply projector-server:
RUN unzip $PROJECTOR_DIR/projector-server-1.0-SNAPSHOT.zip
RUN rm $PROJECTOR_DIR/projector-server-1.0-SNAPSHOT.zip
RUN mv projector-server-1.0-SNAPSHOT $PROJECTOR_DIR/ide/projector-server
RUN mv $PROJECTOR_DIR/ide-projector-launcher.sh $PROJECTOR_DIR/ide/bin
# unzip markdown plugin:
RUN unzip $PROJECTOR_DIR/projector-plugin-markdown-1.0-SNAPSHOT.zip
RUN rm $PROJECTOR_DIR/projector-plugin-markdown-1.0-SNAPSHOT.zip
RUN mv projector-plugin-markdown $PROJECTOR_DIR/projector-plugin-markdown

FROM nginx

RUN true \
# Any command which returns non-zero exit code will cause this shell script to exit immediately:
   && set -e \
# Activate debugging to show execution details: all commands will be printed before execution
   && set -x \
# install packages:
    && apt-get update \
# packages for awt:
    && apt-get install libxext6 libxrender1 libxtst6 libxi6 libfreetype6 -y \
# packages for nginx configuration:
    && apt-get install patch -y \
# packages for user convenience:
    && apt-get install git -y \
# packages for IDEA (to disable warnings):
    && apt-get install procps -y \
# clean apt to reduce image size:
    && rm -rf /var/lib/apt/lists/* \
    && rm -rf /var/cache/apt

ARG downloadUrl

RUN true \
# Any command which returns non-zero exit code will cause this shell script to exit immediately:
    && set -e \
# Activate debugging to show execution details: all commands will be printed before execution
    && set -x \
# install cpecific packages for IDEs:
    && apt-get update \
    && if [ "${downloadUrl#*CLion}" != "$downloadUrl" ]; then apt-get install build-essential clang -y; else echo "Not CLion"; fi \
    && if [ "${downloadUrl#*pycharm}" != "$downloadUrl" ]; then apt-get install python2 python3 python3-distutils python3-pip python3-setuptools -y; else echo "Not pycharm"; fi \
# clean apt to reduce image size:
    && rm -rf /var/lib/apt/lists/* \
    && rm -rf /var/cache/apt

# copy the Projector dir:
ENV PROJECTOR_DIR /projector
COPY --from=projectorStaticFiles $PROJECTOR_DIR $PROJECTOR_DIR

ENV PROJECTOR_USER_NAME projector-user

RUN true \
# Any command which returns non-zero exit code will cause this shell script to exit immediately:
    && set -e \
# Activate debugging to show execution details: all commands will be printed before execution
    && set -x \
# move run scipt:
    && mv $PROJECTOR_DIR/run.sh run.sh \
# prepare nginx:
    && mkdir -p /usr/share/nginx/html/projector \
    && mv $PROJECTOR_DIR/distributions/* /usr/share/nginx/html/projector/ \
    && rm -rf $PROJECTOR_DIR/distributions \
# change user to non-root (http://pjdietz.com/2016/08/28/nginx-in-docker-without-root.html):
    && patch /etc/nginx/nginx.conf < $PROJECTOR_DIR/nginx.conf.patch \
    && rm $PROJECTOR_DIR/nginx.conf.patch \
    && patch /etc/nginx/conf.d/default.conf < $PROJECTOR_DIR/site.conf.patch \
    && rm $PROJECTOR_DIR/site.conf.patch \
    && touch /var/run/nginx.pid \
    && mv $PROJECTOR_DIR/$PROJECTOR_USER_NAME /home \
    && useradd -m -d /home/$PROJECTOR_USER_NAME -s /bin/bash $PROJECTOR_USER_NAME \
    && chown -R $PROJECTOR_USER_NAME.$PROJECTOR_USER_NAME /home/$PROJECTOR_USER_NAME \
    && chown -R $PROJECTOR_USER_NAME.$PROJECTOR_USER_NAME /usr/share/nginx \
    && chown -R $PROJECTOR_USER_NAME.$PROJECTOR_USER_NAME /var/cache/nginx \
    && chown -R $PROJECTOR_USER_NAME.$PROJECTOR_USER_NAME /var/run/nginx.pid \
    && chown -R $PROJECTOR_USER_NAME.$PROJECTOR_USER_NAME $PROJECTOR_DIR/ide/bin \
    && chown $PROJECTOR_USER_NAME.$PROJECTOR_USER_NAME run.sh

USER $PROJECTOR_USER_NAME
ENV HOME /home/$PROJECTOR_USER_NAME
