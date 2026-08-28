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

# Copy the XCall web softphone + brand assets + AI assistant manager + admin panel
COPY portal/webphone/     /var/www/fusionpbx/webphone/
COPY portal/ai-assistant/ /var/www/fusionpbx/ai-assistant/
COPY portal/admin/        /var/www/fusionpbx/admin/
COPY portal/assets/       /var/www/fusionpbx/themes/default/images/
# Rebrand SQL + admin-menu SQL live next to the brand assets so the entrypoint
# can apply them once the DB is up
COPY portal/rebrand/xcall_rebrand.sql /var/www/fusionpbx/themes/default/images/xcall_rebrand.sql
COPY portal/rebrand/admin_menu.sql   /var/www/fusionpbx/themes/default/images/admin_menu.sql

# The stock entrypoint runs php-fpm + nginx + postgres; wrap it so the
# rebrand runs after the DB is up.
COPY docker/portal/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER root
ENTRYPOINT ["/entrypoint.sh"]
