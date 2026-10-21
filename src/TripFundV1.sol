pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {TripFundCore} from "./TripFundCore.sol";

contract TripFundV1 is TripFundCore, Initializable {
    constructor() {
        _disableInitializers();
    }

    function initialize(address token_, address organizer_, uint256 goal_, uint256 deadline_)
        external
        initializer
    {
        _initializeFund(token_, organizer_, goal_, deadline_);
    }
}
