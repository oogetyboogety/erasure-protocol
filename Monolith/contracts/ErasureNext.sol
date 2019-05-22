pragma solidity ^0.5.0;

import "./helpers/openzeppelin-solidity/math/SafeMath.sol";
import "./helpers/openzeppelin-solidity/token/ERC20/ERC20Burnable.sol";

// one to many relationship between Post and Agreement

contract ErasureNext_Monolith {

    using SafeMath for uint256;

    User[] public users;
    Post[] public posts;
    Agreement[] public agreements;

    address public nmr;

    enum GriefType { CgtP, CltP, CeqP, InfGreif, NoGreif }
    enum State { Pending, Accepted, Ended }

    struct User {
        address user;
        bytes metadata;
        uint256 stake;
        bool symmetricGrief;
    }

    struct Post {
        bytes32[] hashes;
        address owner;
        bytes metadata;
        uint256 stake;
        bool symmetricGrief;
    }

    struct Agreement {
        bytes metadata;
        address buyer;
        address seller;
        bool buyerProposed;
        uint256 price;
        uint256 buyerStake;
        uint256 sellerStake;
        uint256 buyerGriefCost;
        uint256 sellerGriefCost;
        uint256 griefDeadline;
        GriefType buyerGriefType;
        GriefType sellerGriefType;
        State status;
    }

    event UserCreated(uint256 userID, address user, bytes metadata, uint256 stake, bool symmetricGrief);
    event UserUpdated(uint256 userID, address user, bytes metadata, uint256 stake, bool symmetricGrief);
    event UserGriefed(uint256 userID, address griefer, uint256 amount, bytes message);
    event PostCreated(uint256 postID, address owner, bytes metadata, uint256 stake, bool symmetricGrief);
    event PostUpdated(uint256 postID, address owner, bytes metadata, uint256 stake, bool symmetricGrief);
    event HashSubmitted(uint256 postID, bytes32 proofHash);
    event PostGriefed(uint256 postID, address griefer, uint256 amount, bytes message);
    event AgreementProposed(
        uint256 agreementID,
        bytes metadata,
        address buyer,
        address seller,
        bool buyerProposed,
        uint256 price,
        uint256 buyerStake,
        uint256 sellerStake,
        uint256 buyerGriefCost,
        uint256 sellerGriefCost,
        uint256 griefDeadline,
        GriefType buyerGriefType,
        GriefType sellerGriefType
    );
    event AgreementAccepted(uint256 agreementID);
    event AgreementGriefed(uint256 agreementID, address griefer, uint256 cost, uint256 punishment, bytes message);
    event AgreementEnded(uint256 agreementID);

    constructor(address _nmr) public {
        nmr = _nmr;
    }

    // USERS //

    function createUser(bytes memory metadata, uint256 stake, bool symmetricGrief) public returns (uint256 userID) {

        userID = users.length;

        // not vulnerable to re-entrancy since token contract is trusted
        require(ERC20Burnable(nmr).transferFrom(msg.sender, address(this), stake));

        users.push(User(msg.sender, metadata, stake, symmetricGrief));

        emit UserCreated(userID, msg.sender, metadata, stake, symmetricGrief);
    }

    function updateUser(uint256 userID, bytes memory metadata, uint256 stake, bool symmetricGrief) public {

        User storage user = users[userID];

        require(msg.sender == user.user, "only user");

        // not vulnerable to re-entrancy since token contract is trusted
        if (stake > user.stake)
            require(ERC20Burnable(nmr).transferFrom(msg.sender, address(this), stake - user.stake));
        if (stake < user.stake)
            require(ERC20Burnable(nmr).transfer(msg.sender, user.stake - stake));

        user.metadata = metadata;
        user.stake = stake;
        user.symmetricGrief = symmetricGrief;

        emit UserUpdated(userID, msg.sender, metadata, stake, symmetricGrief);
    }

    // known to be vulnerable to front-running
    function griefUser(uint256 userID, uint256 amount, bytes memory message) public {

        User storage user = users[userID];

        require(user.symmetricGrief);

        user.stake = user.stake.sub(amount);

        ERC20Burnable(nmr).burn(amount);
        ERC20Burnable(nmr).burnFrom(msg.sender, amount);

        emit UserGriefed(userID, msg.sender, amount, message);
    }

    // POSTS //

    function createPost(bytes32 proofHash, bytes memory metadata, uint256 stake, bool symmetricGrief) public returns (uint256 postID) {

        postID = posts.length;

        require(ERC20Burnable(nmr).transferFrom(msg.sender, address(this), stake));

        bytes32[] memory hashes;

        posts.push(Post(hashes, msg.sender, metadata, stake, symmetricGrief));

        submitHash(postID, proofHash);

        emit PostCreated(postID, msg.sender, metadata, stake, symmetricGrief);
    }

    function submitHash(uint256 postID, bytes32 proofHash) public {

        Post storage post = posts[postID];

        require(msg.sender == post.owner, "only owner");

        post.hashes.push(proofHash);

        emit HashSubmitted(postID, proofHash);
    }

    function updatePost(uint256 postID, bytes memory metadata, uint256 stake, bool symmetricGrief) public {

        Post storage post = posts[postID];

        require(msg.sender == post.owner, "only owner");

        // not vulnerable to re-entrancy since token contract is trusted
        if (stake > post.stake)
            require(ERC20Burnable(nmr).transferFrom(msg.sender, address(this), stake - post.stake));
        if (stake < post.stake)
            require(ERC20Burnable(nmr).transfer(msg.sender, post.stake - stake));

        post.metadata = metadata;
        post.stake = stake;
        post.symmetricGrief = symmetricGrief;

        emit PostUpdated(postID, msg.sender, metadata, stake, symmetricGrief);
    }

    // known to be vulnerable to front-running
    function griefPost(uint256 postID, uint256 amount, bytes memory message) public {

        Post storage post = posts[postID];

        require(post.symmetricGrief);

        post.stake = post.stake.sub(amount);

        ERC20Burnable(nmr).burn(amount);
        ERC20Burnable(nmr).burnFrom(msg.sender, amount);

        emit PostGriefed(postID, msg.sender, amount, message);
    }

    // AGREEMENTS //

    function proposeAgreement(
        bool isBuyer,
        address counterparty,
        bytes memory metadata,
        uint256 price,
        uint256 buyerStake,
        uint256 sellerStake,
        uint256 buyerGriefCost,
        uint256 sellerGriefCost,
        uint256 griefDeadline,
        GriefType buyerGriefType,
        GriefType sellerGriefType
    ) public returns (uint256 agreementID){

        if (isBuyer) {
            agreementID = pushProposal(
                metadata,
                msg.sender,
                counterparty,
                isBuyer,
                price,
                buyerStake,
                sellerStake,
                buyerGriefCost,
                sellerGriefCost,
                griefDeadline,
                buyerGriefType,
                sellerGriefType
            );
        } else {
            agreementID = pushProposal(
                metadata,
                counterparty,
                msg.sender,
                isBuyer,
                price,
                buyerStake,
                sellerStake,
                buyerGriefCost,
                sellerGriefCost,
                griefDeadline,
                buyerGriefType,
                sellerGriefType
            );
        }


    }

    function pushProposal(
        bytes memory metadata,
        address buyer,
        address seller,
        bool isBuyer,
        uint256 price,
        uint256 buyerStake,
        uint256 sellerStake,
        uint256 buyerGriefCost,
        uint256 sellerGriefCost,
        uint256 griefDeadline,
        GriefType buyerGriefType,
        GriefType sellerGriefType
    ) private returns (uint256 agreementID) {

        agreementID = agreements.length;

        agreements.push(Agreement(
            metadata,
            buyer,
            seller,
            isBuyer,
            price,
            buyerStake,
            sellerStake,
            buyerGriefCost,
            sellerGriefCost,
            griefDeadline,
            buyerGriefType,
            sellerGriefType,
            State.Pending
        ));

        emit AgreementProposed(
            agreementID,
            metadata,
            buyer,
            seller,
            isBuyer,
            price,
            buyerStake,
            sellerStake,
            buyerGriefCost,
            sellerGriefCost,
            griefDeadline,
            buyerGriefType,
            sellerGriefType
        );
    }

    function acceptAgreement(uint256 agreementID) public {

        Agreement storage agreement = agreements[agreementID];

        if (agreement.buyerProposed)
            require(msg.sender == agreement.seller, "only seller");
        else
            require(msg.sender == agreement.buyer, "only seller");

        require(agreement.status == State.Pending, "only pending");

        // transfer price
        require(ERC20Burnable(nmr).transferFrom(agreement.buyer, agreement.seller, agreement.price));

        // transfer stakes
        require(ERC20Burnable(nmr).transferFrom(agreement.seller, address(this), agreement.sellerStake));
        require(ERC20Burnable(nmr).transferFrom(agreement.buyer, address(this), agreement.buyerStake));

        agreement.status = State.Accepted;

        emit AgreementAccepted(agreementID);
    }

    function griefAgreement(uint256 agreementID, uint256 punishment, bytes memory message) public {

        Agreement storage agreement = agreements[agreementID];

        require(msg.sender == agreement.seller || msg.sender == agreement.buyer, "only seller or buyer");
        require(now < agreement.griefDeadline, "only before grief deadline");
        require(agreement.status == State.Accepted, "only accepted agreements");

        uint256 cost;

        if (msg.sender == agreement.seller) {
            cost = getGriefCost(agreement.sellerGriefCost, punishment, agreement.sellerGriefType);

            agreement.sellerStake = agreement.sellerStake.sub(cost);
            agreement.buyerStake = agreement.buyerStake.sub(punishment);
        } else {
            cost = getGriefCost(agreement.buyerGriefCost, punishment, agreement.buyerGriefType);

            agreement.sellerStake = agreement.sellerStake.sub(punishment);
            agreement.buyerStake = agreement.buyerStake.sub(cost);
        }

        ERC20Burnable(nmr).burn(punishment.add(cost));

        emit AgreementGriefed(agreementID, msg.sender, cost, punishment, message);
    }

    function endAgreement(uint256 agreementID) public {

        Agreement storage agreement = agreements[agreementID];

        require(msg.sender == agreement.seller || msg.sender == agreement.buyer, "only seller or buyer");
        require(agreement.status != State.Ended, "only active agreements");

        if (agreement.status == State.Accepted) {
            require(now > agreement.griefDeadline, "only after grief deadline");

            // not vulnerable to re-entrancy since token contract is trusted
            require(ERC20Burnable(nmr).transfer(agreement.seller, agreement.sellerStake));
            require(ERC20Burnable(nmr).transfer(agreement.buyer, agreement.buyerStake));

            delete agreement.sellerStake;
            delete agreement.buyerStake;
        } else {
            require(agreement.status == State.Pending, "only pending agreements");
        }

        agreement.status = State.Ended;

        emit AgreementEnded(agreementID);
    }

    function getGriefCost(uint256 ratio, uint256 punishment, GriefType griefType) public pure returns(uint256 cost) {
        /*
            CgtP: Cost greater than Punishment
            CltP: Cost less than Punishment
            CeqP: Cost equal to Punishment
            InfGrief: Punishment at no cost
            NoGrief: No Punishment
        */
        if (griefType == GriefType.CgtP)
            return punishment.mul(ratio);
        if (griefType == GriefType.CltP)
            return punishment.div(ratio);
        if (griefType == GriefType.CeqP)
            return punishment;
        if (griefType == GriefType.InfGreif)
            return 0;
        if (griefType == GriefType.NoGreif)
            revert();
    }

}