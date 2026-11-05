# Umgebung fuer die gebuendelte Perl-Laufzeit des FHEM-Add-ons.
# Nutzung auf der CCU per SSH:   . /usr/local/addons/fhem/bin/fhem-env.sh
#                                perl -v

FHEM_ADDON_DIR=/usr/local/addons/fhem
FHEM_HOME=$FHEM_ADDON_DIR/fhem
FHEM_PERL=$FHEM_ADDON_DIR/perl/bin/perl

case ":$PATH:" in
  *":$FHEM_ADDON_DIR/perl/bin:"*) ;;
  *) PATH=$FHEM_ADDON_DIR/perl/bin:$PATH ;;
esac
export PATH FHEM_ADDON_DIR FHEM_HOME FHEM_PERL

# CA-Zertifikate fuer HTTPS (IO::Socket::SSL wertet SSL_CERT_FILE aus).
# Bevorzugt die Zertifikate des OpenCCU-Systems, sonst die mitgelieferten.
if [ -z "$SSL_CERT_FILE" ]; then
  for f in /etc/ssl/certs/ca-certificates.crt /etc/ssl/cert.pem /etc/ssl/certs/ca-bundle.crt \
           "$FHEM_ADDON_DIR/etc/cacert.pem"; do
    if [ -s "$f" ]; then SSL_CERT_FILE=$f; export SSL_CERT_FILE; break; fi
  done
fi
