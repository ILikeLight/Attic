#ifndef __CONFIG_H__
#define __CONFIG_H__

/* Changed by Attic: 1024 like Apple's own MAXPATHLEN, instead of 256. Paths inside
 * an iOS app container are long (in the Simulator often longer than 255 characters),
 * and PCSX cut them off, so games and memory cards could not be opened. */
#define MAXPATHLEN 1024
#define PCSX_VERSION "1.9"

#endif /* __CONFIG_H__ */
