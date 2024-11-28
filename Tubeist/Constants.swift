//
//  Constants.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2024-11-26.
//

import CoreFoundation

// From: https://gist.github.com/shinyquagsire23/81c86f4bf670aaa68b5804080ff964a0

//
// Non-conclusive list of interesting private Metal pixel formats
//
let MTLPixelFormatYCBCR8_420_2P: UInt = 500
let MTLPixelFormatYCBCR8_422_1P: UInt = 501
let MTLPixelFormatYCBCR8_422_2P: UInt = 502
let MTLPixelFormatYCBCR8_444_2P: UInt = 503
let MTLPixelFormatYCBCR10_444_1P: UInt = 504
let MTLPixelFormatYCBCR10_420_2P: UInt = 505
let MTLPixelFormatYCBCR10_422_2P: UInt = 506
let MTLPixelFormatYCBCR10_444_2P: UInt = 507
let MTLPixelFormatYCBCR10_420_2P_PACKED: UInt = 508
let MTLPixelFormatYCBCR10_422_2P_PACKED: UInt = 509
let MTLPixelFormatYCBCR10_444_2P_PACKED: UInt = 510

let MTLPixelFormatYCBCR8_420_2P_sRGB: UInt = 520
let MTLPixelFormatYCBCR8_422_1P_sRGB: UInt = 521
let MTLPixelFormatYCBCR8_422_2P_sRGB: UInt = 522
let MTLPixelFormatYCBCR8_444_2P_sRGB: UInt = 523
let MTLPixelFormatYCBCR10_444_1P_sRGB: UInt = 524
let MTLPixelFormatYCBCR10_420_2P_sRGB: UInt = 525
let MTLPixelFormatYCBCR10_422_2P_sRGB: UInt = 526
let MTLPixelFormatYCBCR10_444_2P_sRGB: UInt = 527
let MTLPixelFormatYCBCR10_420_2P_PACKED_sRGB: UInt = 528
let MTLPixelFormatYCBCR10_422_2P_PACKED_sRGB: UInt = 529
let MTLPixelFormatYCBCR10_444_2P_PACKED_sRGB: UInt = 530

let MTLPixelFormatRGB8_420_2P: UInt = 540
let MTLPixelFormatRGB8_422_2P: UInt = 541
let MTLPixelFormatRGB8_444_2P: UInt = 542
let MTLPixelFormatRGB10_420_2P: UInt = 543
let MTLPixelFormatRGB10_422_2P: UInt = 544
let MTLPixelFormatRGB10_444_2P: UInt = 545
let MTLPixelFormatRGB10_420_2P_PACKED: UInt = 546
let MTLPixelFormatRGB10_422_2P_PACKED: UInt = 547
let MTLPixelFormatRGB10_444_2P_PACKED: UInt = 548

let MTLPixelFormatRGB10A8_2P_XR10: UInt = 550
let MTLPixelFormatRGB10A8_2P_XR10_sRGB: UInt = 551
let MTLPixelFormatBGRA10_XR: UInt = 552
let MTLPixelFormatBGRA10_XR_sRGB: UInt = 553
let MTLPixelFormatBGR10_XR: UInt = 554
let MTLPixelFormatBGR10_XR_sRGB: UInt = 555
let MTLPixelFormatRGBA16Float_XR: UInt = 556

let MTLPixelFormatYCBCRA8_444_1P: UInt = 560

let MTLPixelFormatYCBCR12_420_2P: UInt = 570
let MTLPixelFormatYCBCR12_422_2P: UInt = 571
let MTLPixelFormatYCBCR12_444_2P: UInt = 572
let MTLPixelFormatYCBCR12_420_2P_PQ: UInt = 573
let MTLPixelFormatYCBCR12_422_2P_PQ: UInt = 574
let MTLPixelFormatYCBCR12_444_2P_PQ: UInt = 575
let MTLPixelFormatR10Unorm_X6: UInt = 576
let MTLPixelFormatR10Unorm_X6_sRGB: UInt = 577
let MTLPixelFormatRG10Unorm_X12: UInt = 578
let MTLPixelFormatRG10Unorm_X12_sRGB: UInt = 579
let MTLPixelFormatYCBCR12_420_2P_PACKED: UInt = 580
let MTLPixelFormatYCBCR12_422_2P_PACKED: UInt = 581
let MTLPixelFormatYCBCR12_444_2P_PACKED: UInt = 582
let MTLPixelFormatYCBCR12_420_2P_PACKED_PQ: UInt = 583
let MTLPixelFormatYCBCR12_422_2P_PACKED_PQ: UInt = 584
let MTLPixelFormatYCBCR12_444_2P_PACKED_PQ: UInt = 585
let MTLPixelFormatRGB10A2Unorm_sRGB: UInt = 586
let MTLPixelFormatRGB10A2Unorm_PQ: UInt = 587
let MTLPixelFormatR10Unorm_PACKED: UInt = 588
let MTLPixelFormatRG10Unorm_PACKED: UInt = 589
let MTLPixelFormatYCBCR10_444_1P_XR: UInt = 590
let MTLPixelFormatYCBCR10_420_2P_XR: UInt = 591
let MTLPixelFormatYCBCR10_422_2P_XR: UInt = 592
let MTLPixelFormatYCBCR10_444_2P_XR: UInt = 593
let MTLPixelFormatYCBCR10_420_2P_PACKED_XR: UInt = 594
let MTLPixelFormatYCBCR10_422_2P_PACKED_XR: UInt = 595
let MTLPixelFormatYCBCR10_444_2P_PACKED_XR: UInt = 596
let MTLPixelFormatYCBCR12_420_2P_XR: UInt = 597
let MTLPixelFormatYCBCR12_422_2P_XR: UInt = 598
let MTLPixelFormatYCBCR12_444_2P_XR: UInt = 599
let MTLPixelFormatYCBCR12_420_2P_PACKED_XR: UInt = 600
let MTLPixelFormatYCBCR12_422_2P_PACKED_XR: UInt = 601
let MTLPixelFormatYCBCR12_444_2P_PACKED_XR: UInt = 602
let MTLPixelFormatR12Unorm_X4: UInt = 603
let MTLPixelFormatR12Unorm_X4_PQ: UInt = 604
let MTLPixelFormatRG12Unorm_X8: UInt = 605
let MTLPixelFormatR10Unorm_X6_PQ: UInt = 606

// https://github.com/WebKit/WebKit/blob/f86d3400c875519b3f3c368f1ea9a37ed8a1d11b/Source/WebGPU/WebGPU/BindGroup.mm#L43
let kCVPixelFormatType_420YpCbCr10PackedBiPlanarFullRange = 0x70663230 as OSType // pf20
let kCVPixelFormatType_422YpCbCr10PackedBiPlanarFullRange = 0x70663232 as OSType // pf22
let kCVPixelFormatType_444YpCbCr10PackedBiPlanarFullRange = 0x70663434 as OSType // pf44

let kCVPixelFormatType_420YpCbCr10PackedBiPlanarVideoRange = 0x70343230 as OSType // p420
let kCVPixelFormatType_422YpCbCr10PackedBiPlanarVideoRange = 0x70343232 as OSType // p422
let kCVPixelFormatType_444YpCbCr10PackedBiPlanarVideoRange = 0x70343434 as OSType // p444

// Other formats Apple forgot
let kCVPixelFormatType_Lossy_420YpCbCr10PackedBiPlanarFullRange = 0x2D786630 as OSType // -xf0
let kCVPixelFormatType_Lossless_422YpCbCr10PackedBiPlanarFullRange = 0x26786632 as OSType // &xf2
let kCVPixelFormatType_Lossy_422YpCbCr10PackedBiPlanarFullRange = 0x2D786632 as OSType // -xf2
