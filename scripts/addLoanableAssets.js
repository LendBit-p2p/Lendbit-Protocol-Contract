const { ethers } = require("hardhat")

async function addLoanableAssets() {
    const accounts = await ethers.getSigners()
    // const contractOwner = accounts[0]
    const DIAMOND_ADDRESS = '0xA8a18f94aE2b1D27bCDB4e400cE709E10ADa32ca'
    const diamond = await ethers.getContractAt('ProtocolFacet', DIAMOND_ADDRESS)

    // address USDT_USD = 0x3ec8593F930EA45ea58c968260e6e9FF53FC934f;
    // address WETH_USD = 0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1;
    // address DIA_USD = 0xD1092a65338d049DB68D7Be6bD89d17a0929945e;
    // address LINK_USD = 0xb113F5A928BCfF189C998ab20d753a47F9dE5A61;

    // address USDT_CONTRACT_ADDRESS = 0x00D1C02E008D594ebEFe3F3b7fd175850f96AEa0;
    // address WETH_CONTRACT_ADDRESS = 0x7fEa3ea63433a35e8516777171D7d0e038804716;
    // address DIA_CONTRACT_ADDRESS = 0x5caF98bf477CBE96d5CA56039FE7beec457bA653;
    // address LINK_CONTRACT_ADDRESS = 0xE4aB69C077896252FAFBD49EFD26B5D171A32410;

    const assets = [
        "0x00D1C02E008D594ebEFe3F3b7fd175850f96AEa0",
        "0x7fEa3ea63433a35e8516777171D7d0e038804716",
        "0x5caF98bf477CBE96d5CA56039FE7beec457bA653",
        "0xE4aB69C077896252FAFBD49EFD26B5D171A32410",
        "0x0000000000000000000000000000000000000001"
    ]
    const priceFeeds = [
        "0x3ec8593F930EA45ea58c968260e6e9FF53FC934f",
        "0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1",
        "0xD1092a65338d049DB68D7Be6bD89d17a0929945e",
        "0xb113F5A928BCfF189C998ab20d753a47F9dE5A61",
        "0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1"
    ]

    // await assets.forEach(async (asset, index) => {
    //     let tx = await diamond.addLoanableToken(asset, priceFeeds[index])
    //     console.log(`Adding asset ${asset} with price feed ${priceFeeds[index]}`)
    //     await tx.wait()
    //     console.log(`Transaction hash: ${tx.hash}`)
    // })

    // diamond.getLoanableAssets().then((value) => {
    //     console.log(`Loanable assets: ${value}`)
    // })
    // const tx = await diamond.initialize(assets, priceFeeds)
    // await tx.wait()

    diamond.getAllCollateralToken().then((value) => {
        console.log(`Loanable assets: ${value}`)
    })
}

async function main() {
    addLoanableAssets()
}

main().catch((error) => {
    consolejson.log(error)
    process.exit(1)
})