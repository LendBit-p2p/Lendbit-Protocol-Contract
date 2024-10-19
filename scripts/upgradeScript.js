const fs = require("fs");
const { getSelectors, FacetCutAction } = require('./libraries/diamond.js')
const { ethers } = require('hardhat')
async function deployDiamond() {
    const accounts = await ethers.getSigners()
    const contractOwner = accounts[0]

    // DiamondCutFacet deployed: 0xa513E6E4b8f2a923D98304ec87F64353C4D5C853
    // Diamond deployed: 0x2279B7A0a67DB372996a5FaB50D91eAA73d2eBe6
    // DiamondInit deployed: 0x8A791620dd6260079BF849Dc5567aDC3F2FdC318

    // Deploying facets
    // DiamondLoupeFacet deployed: 0x610178dA211FEF7D417bC0e6FeD39F05609AD788
    // OwnershipFacet deployed: 0xB7f8BC63BbcaD18155201308C8f3540b07f84F5e
    // ProtocolFacet deployed: 0xA51c1fc2f0D1a1b8494Ed1FE312d7C3a78Ed91C0

    const DiamondCutFacetAddress = "0xB4D8429C2De32f059c087735d1b9A104CCec090b"
    const DiamondAddress = "0x3593bB3E80BC188E10523178874Ee736C3091D06"
    const DiamondInitAddress = "0xf5579197e85d7444c0d69C835F36c572F9412757"


    // deploy DiamondCutFacet
    const DiamondCutFacet = await ethers.getContractFactory('DiamondCutFacet')
    // const diamondCutFacet = await DiamondCutFacet.deploy()
    // await diamondCutFacet.deployed()
    // console.log('DiamondCutFacet deployed:', diamondCutFacet.address)


    // deploy Diamond
    const Diamond = await ethers.getContractFactory('Diamond')
    // const diamond = await Diamond.deploy(
    //     contractOwner.address,
    //     diamondCutFacet.address,
    // )
    // await diamond.deployed()
    // console.log('Diamond deployed:', diamond.address)


    // deploy DiamondInit
    // DiamondInit provides a function that is called when the diamond is upgraded to initialize state variables
    // Read about how the diamondCut function works here: https://eips.ethereum.org/EIPS/eip-2535#addingreplacingremoving-functions
    const DiamondInit = await ethers.getContractFactory('DiamondInit')
    // const diamondInit = await DiamondInit.deploy()
    // await diamondInit.deployed()
    // console.log('DiamondInit deployed:', diamondInit.address)


    // deploy facets
    console.log('')
    console.log('Deploying facets')
    const FacetNames = ['ProtocolFacet']

    const prevProtocolFacet = await ethers.getContractAt('ProtocolFacet', '0x07Fcd6Fdaf587f0D35b7cf299c6Dc7f39ae86638')
    const cut = [{
        facetAddress: "0x07Fcd6Fdaf587f0D35b7cf299c6Dc7f39ae86638",
        action: FacetCutAction.Remove,
        functionSelectors: getSelectors(prevProtocolFacet),
    }]

    for (const FacetName of FacetNames) {
        const Facet = await ethers.getContractFactory(FacetName)
        const facet = await Facet.deploy()
        await facet.deployed()


        fs.writeFile(`./scripts/abi/${FacetName}.json`, JSON.stringify(Facet.interface, null, 2), { flag: "w" }, (err) => {
            if (err) {
                console.error(err)
                return
            }
        })
        console.log(`${FacetName} deployed: ${facet.address}`)
        cut.push({
            facetAddress: facet.address,
            action: FacetCutAction.Add,
            functionSelectors: getSelectors(facet),
        })
    }


    // upgrade diamond with facets
    console.log('')
    console.log('Diamond Cut:', cut)
    const diamondCut = await ethers.getContractAt('IDiamondCut', DiamondAddress)
    let tx
    let receipt
    // call to init function
    let functionCall = DiamondInit.interface.encodeFunctionData('init')
    tx = await diamondCut.diamondCut(cut, DiamondInitAddress, functionCall)
    console.log('Diamond cut tx: ', tx.hash)
    receipt = await tx.wait()
    if (!receipt.status) {
        throw Error(`Diamond upgrade failed: ${tx.hash}`)
    }
    console.log('Completed diamond cut')
    return DiamondAddress
}


// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
if (require.main === module) {
    deployDiamond()
        .then(() => process.exit(0))
        .catch((error) => {
            console.error(error)
            process.exit(1)
        })
}


exports.deployDiamond = deployDiamond

