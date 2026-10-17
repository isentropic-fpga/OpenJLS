/*
 * Copyright (C) 2026 Vitor Mendes Camilo
 * SPDX-License-Identifier: GPL-3.0-only
 *
 * This file is part of OpenJLS. Available under GPLv3 or a
 * commercial license. See LICENSE and README for details.
 */

/* ojls_regs.h: openjls_axis_regs register map, byte offsets of 32-bit registers */

#ifndef OJLS_REGS_H
#define OJLS_REGS_H

#define OJLS_REG_ID      0x00u /* RO: ASCII "OJLS"                                        */
#define OJLS_REG_VERSION 0x04u /* RO: 0x00MMmmpp (major/minor/patch)                      */
#define OJLS_REG_CAPS    0x08u /* RO: [7:0] BITNESS, [15:8] output bytes/beat             */
#define OJLS_REG_MAXDIM  0x0Cu /* RO: [15:0] MAX_IMAGE_WIDTH, [31:16] MAX_IMAGE_HEIGHT    */
#define OJLS_REG_WIDTH   0x10u /* RW: [15:0] image width (clamped on write)               */
#define OJLS_REG_HEIGHT  0x14u /* RW: [15:0] image height (clamped on write)              */
#define OJLS_REG_CTRL    0x18u /* WO: [0] APPLY — self-clearing, pulses the core reset    */
#define OJLS_REG_STATUS  0x1Cu /* RO: [0] BUSY, [1] S_AXIS_TREADY mirror                  */

#define OJLS_ID_VALUE      0x4F4A4C53u /* "OJLS" */
#define OJLS_CTRL_APPLY    0x1u
#define OJLS_STATUS_BUSY   0x1u
#define OJLS_STATUS_TREADY 0x2u

#define OJLS_CAPS_BITNESS(caps)    ((caps) & 0xFFu)
#define OJLS_CAPS_OUT_BYTES(caps)  (((caps) >> 8) & 0xFFu)
#define OJLS_MAXDIM_WIDTH(maxdim)  ((maxdim) & 0xFFFFu)
#define OJLS_MAXDIM_HEIGHT(maxdim) (((maxdim) >> 16) & 0xFFFFu)

/* CO_MIN_IMAGE_WIDTH/HEIGHT in openjls_pkg.vhd */
#define OJLS_MIN_WIDTH  4u
#define OJLS_MIN_HEIGHT 1u

#endif /* OJLS_REGS_H */
