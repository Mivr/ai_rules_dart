#include "LocalSettings.h"

int local_settings_public_consumer(void) {
    return local_settings_value();
}
