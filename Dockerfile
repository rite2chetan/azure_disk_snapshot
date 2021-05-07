# For SLES 12 sp 3 testing
FROM opensuse/leap:42.3
# For SLES 15 testing
#FROM opensuse/leap:15.2
RUN zypper in -y make
WORKDIR /app
COPY . .
RUN make install
CMD tail -f /dev/null
