/*
 * Build-time limits shared by C and assembly (start.S includes this file),
 * so it must contain only preprocessor definitions.
 */
#ifndef LAZUL_CONFIG_H
#define LAZUL_CONFIG_H

#define	STACK_SHIFT	17	/* 128 KiB per hart; mruby recurses deeply */
#define	TLS_AREA	256	/* bytes of thread-local storage per hart */

#endif
