# XCall — portal image (rebranded FusionPBX + web softphone).
#
# Base: the official FusionPBX Docker image (nginx + php-fpm + postgres).
# We overlay:
#   - the XCall web softphone under /webphone
#   - the brand assets + stylesheet
#   - apply the branding SQL on first boot
#
# The FusionPBX image runs its own postgres inside the container by default;
# for a serious deployment put postgres in its own container/volume.

FROM fusionpbx/fusionpbx:latest

USER root

# Copy the XCall web softphone + brand assets
COPY portal/webphone/ /var/www/fusionpbx/webphone/
COPY portal/assets/   /var/www/fusionpbx/themes/default/images/

# Rebrand bootstrap script (applies DB brand settings after install)
COPY docker/portal/rebrand-on-boot.sh /usr/local/bin/rebrand-on-boot.sh
RUN chmod +x /usr/local/bin/rebrand-on-boot.sh

# The stock entrypoint runs php-fpm + nginx + postgres; wrap it so the
# rebrand runs after the DB is up.
COPY docker/portal/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER root
ENTRYPOINT ["/entrypoint.sh"]
